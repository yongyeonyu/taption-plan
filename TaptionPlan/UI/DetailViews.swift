import MapKit
import PhotosUI
import SwiftUI

#if canImport(FamilyControls) && canImport(ManagedSettings)
import FamilyControls
import ManagedSettings
#endif

struct QuickActionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let item: QuickActionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Color(red: 0.84, green: 0.84, blue: 0.86))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 14)

            HStack(spacing: 8) {
                Text(item.title)
                    .font(.taption(size: 16, weight: .bold))
                Spacer()
                if let planID = item.planID {
                    Button {
                        dismiss()
                        Task { @MainActor in
                            model.planEditorRequest = PlanEditorRequest(
                                id: planID
                            )
                        }
                    } label: {
                        Label("편집", systemImage: "slider.horizontal.3")
                            .font(.taption(size: 9, weight: .bold))
                            .foregroundStyle(Color.tpSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                Color.tpBackground,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 14)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.time)
                        .font(.taption(size: 15, weight: .bold))
                    Text(item.context)
                        .font(.taption(size: 11))
                        .foregroundStyle(Color.tpSecondary)
                }
                Spacer(minLength: 4)
                if item.planID != nil {
                    Button {
                        run {
                            id in await model.addPlanToCalendar(id)
                        }
                    } label: {
                        Image(
                            systemName: selectedPlan?.externalEventID == nil
                                ? "calendar.badge.plus"
                                : "checkmark.circle.fill"
                        )
                        .font(.taption(size: 16, weight: .semibold))
                        .foregroundStyle(
                            selectedPlan?.externalEventID == nil
                                ? Color.tpSecondary
                                : Color(red: 0.18, green: 0.52, blue: 0.32)
                        )
                        .frame(width: 34, height: 34)
                        .background(
                            Color.white,
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedPlan?.externalEventID != nil)
                    .accessibilityLabel(
                        selectedPlan?.externalEventID == nil
                            ? "캘린더로 보내기"
                            : "캘린더에 추가됨"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color.tpBackground, in: RoundedRectangle(cornerRadius: 13))
            .padding(.bottom, 12)

            // 메모 입력은 하단 메뉴의 메모 추가 버튼에서 시작한다.
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.taption(size: 15))
                VStack(alignment: .leading, spacing: 2) {
                    Text("메모 \(itemMemos.count)개")
                        .font(.taption(size: 10.5, weight: .bold))
                        .foregroundStyle(Color.tpInk)
                    Text(lastMemoLabel)
                        .font(.taption(size: 9))
                        .foregroundStyle(Color.tpSecondary)
                }
                Spacer()
            }
            .foregroundStyle(Color.tpStudyDark)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                Color(red: 0.95, green: 0.94, blue: 0.97),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .padding(.bottom, 10)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                actionButton("play.fill", "시작", style: .primary) {
                    run { planID in await model.startPlan(planID) }
                }
                actionButton("checkmark", "했어요") {
                    run {
                        planID in await model.performQuickAction(.complete, planID: planID)
                    }
                }
                actionButton("clock", "30분 미루기", style: .health) {
                    run {
                        planID in
                        await model.performQuickAction(
                            .postponeThirtyMinutes,
                            planID: planID
                        )
                    }
                }
                actionButton("location.north", "다음 빈 시간") {
                    run {
                        planID in
                        await model.performQuickAction(
                            .moveToNextFreeTime,
                            planID: planID
                        )
                    }
                }
                actionButton("arrow.counterclockwise", "오늘은 건너뜀") {
                    run { planID in await model.skipPlan(planID) }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 28)
        .presentationDetents([.height(390)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(22)
    }

    private enum ActionStyle {
        case regular
        case primary
        case health
    }

    private func actionButton(
        _ icon: String,
        _ title: String,
        style: ActionStyle = .regular,
        action: @escaping () -> Void = {}
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.taption(size: 12, weight: .bold))
                .foregroundStyle(style == .primary ? Color.white : style == .health ? Color(red: 0.55, green: 0.20, blue: 0.16) : Color.tpInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    style == .primary ? Color.tpInk : style == .health ? Color.tpExercise : Color(red: 0.94, green: 0.94, blue: 0.95),
                    in: RoundedRectangle(cornerRadius: 12)
                )
        }
        .buttonStyle(.plain)
    }

    private func run(
        _ operation: @escaping @MainActor (UUID) async -> Void
    ) {
        guard let planID = item.planID else {
            dismiss()
            return
        }
        dismiss()
        Task { await operation(planID) }
    }

    private var itemMemos: [ActionMemo] {
        model.memos(for: item.planID)
    }

    private var selectedPlan: PlanRecord? {
        guard let planID = item.planID else { return nil }
        return model.snapshot.plans.first { $0.id == planID }
    }

    private var lastMemoLabel: String {
        guard let last = itemMemos.last else {
            return "아직 남긴 메모가 없습니다"
        }
        return "마지막 기록 · \(last.createdAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// 메모 입력의 유일한 화면. 계획도 기록도 고르지 않고 순간 하나에만 매인다.
/// 키보드는 메모 글에만 쓰고, 시각은 손가락으로 고른다.
struct MemoDetailView: View {
    @Bindable var model: AppModel
    @State private var selectedMemoKind: MemoKind = .decision
    @State private var memo = ""
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var editingMemoID: UUID?
    @State private var dragOriginSpan: TimeSpan?
    @State private var dragStartedAt: Date?
    @State private var lastFeedbackDate: Date?
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(
                title: "메모",
                trailing: "완료",
                trailingColor: Color(red: 0.20, green: 0.47, blue: 0.72)
            ) {
                model.closeMemoEntry()
            }

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        instantCard
                        savedMemoList
                        composer
                            .id("memo-composer")
                    }
                    .padding(12)
                    .padding(.bottom, composerFocused ? 16 : 0)
                }
                .background(Color.tpBackground)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: composerFocused) { _, focused in
                    guard focused else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(80))
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("memo-composer", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let identifier = item?.itemIdentifier else { return }
            model.addAttachmentMemoAtEntryInstant(
                kind: selectedMemoKind,
                attachmentKind: .photo,
                localIdentifier: identifier
            )
            selectedPhotoItem = nil
        }
    }

    // MARK: - 시각

    private var instantCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(
                    instant.formatted(
                        Date.FormatStyle(date: .abbreviated, time: .omitted)
                    )
                )
                .font(.taption(size: 9.5, weight: .bold))
                .foregroundStyle(Color.tpStudyDark)
                Text(
                    instant.formatted(date: .omitted, time: .shortened)
                )
                .font(.taption(size: 20, weight: .bold))
                Spacer(minLength: 4)
                Button {
                    model.moveMemoEntry(to: .now)
                } label: {
                    Text("지금")
                        .font(.taption(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.tpInk)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            Color(red: 0.94, green: 0.94, blue: 0.95),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                }
                .buttonStyle(.plain)
            }

            timeStrip

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .draftCard(radius: 15)
    }

    /// 시각은 손가락 하나로만 고른다. 시간표 막대와 같은 속도 감응 규칙
    /// (`TimeSliderEngine`)을 써서 화면마다 다른 감각이 생기지 않게 한다.
    private var timeStrip: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(red: 0.92, green: 0.92, blue: 0.94))
                    .frame(height: 8)
                Capsule()
                    .fill(Color.tpStudyDark.opacity(0.55))
                    .frame(width: knobX(width: width), height: 8)
                Circle()
                    .fill(Color.white)
                    .frame(width: 22, height: 22)
                    .overlay {
                        Circle().stroke(Color.tpStudyDark, lineWidth: 2)
                    }
                    .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
                    .offset(x: knobX(width: width) - 11)
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            .gesture(stripDrag(width: width))
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityLabel("메모 시각")
        .accessibilityValue(
            instant.formatted(date: .omitted, time: .shortened)
        )
        .accessibilityAdjustableAction { direction in
            let step: TimeInterval = direction == .increment ? 600 : -600
            model.moveMemoEntry(to: clamped(instant.addingTimeInterval(step)))
        }
    }

    private func knobX(width: CGFloat) -> CGFloat {
        let fraction = instant.timeIntervalSince(dayBounds.start)
            / max(1, dayBounds.duration)
        return width * CGFloat(max(0, min(1, fraction)))
    }

    private func stripDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let now = Date.now
                if dragOriginSpan == nil {
                    dragOriginSpan = TimeSpan(start: instant, end: instant)
                    dragStartedAt = now
                    lastFeedbackDate = instant
                }
                guard let origin = dragOriginSpan,
                      let began = dragStartedAt else {
                    return
                }
                let elapsed = max(0.016, now.timeIntervalSince(began))
                let velocity = Double(value.translation.width) / elapsed
                let delta = Double(value.translation.width / width)
                    * dayBounds.duration
                let adjusted = TimeSliderEngine.adjust(
                    origin,
                    handle: .body,
                    delta: delta,
                    velocityPointsPerSecond: velocity,
                    isLongPressPrecision: elapsed >= 0.35,
                    bounds: dayBounds,
                    minimumDuration: 0
                )
                if let lastFeedbackDate,
                   TimeSliderEngine.crossedTenMinuteTick(
                       previous: lastFeedbackDate,
                       current: adjusted.start
                   ) {
                    UISelectionFeedbackGenerator().selectionChanged()
                    self.lastFeedbackDate = adjusted.start
                }
                model.moveMemoEntry(to: clamped(adjusted.start))
            }
            .onEnded { _ in
                dragOriginSpan = nil
                dragStartedAt = nil
                lastFeedbackDate = nil
            }
    }

    private func clamped(_ date: Date) -> Date {
        min(max(date, dayBounds.start), dayBounds.end)
    }

    private var instant: Date {
        model.memoEntry?.occurredAt ?? .now
    }

    private var dayBounds: TimeSpan {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: instant)
        return TimeSpan(
            start: start,
            end: calendar.date(byAdding: .day, value: 1, to: start)
                ?? start.addingTimeInterval(86_400)
        )
    }

    // MARK: - 목록

    private var savedMemoList: some View {
        VStack(spacing: 8) {
            if entryMemos.isEmpty {
                ContentUnavailableView(
                    "이 시각에는 아직 메모가 없습니다",
                    systemImage: "note.text",
                    description: Text("결정이나 아이디어를 짧게 남겨보세요.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                ForEach(entryMemos) { entry in
                    memoEntryRow(entry)
                }
            }
        }
    }

    private func memoEntryRow(_ entry: ActionMemo) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(entry.occurredAt.formatted(date: .omitted, time: .shortened))
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)
                .frame(width: 38, alignment: .trailing)
                .padding(.top, 9)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(entry.kind.displayName)
                        .font(.taption(size: 9, weight: .bold))
                        .foregroundStyle(Color.tpStudyDark)
                    Spacer()
                    Menu {
                        Button("수정", systemImage: "pencil") {
                            beginEditing(entry)
                        }
                        Button(
                            "삭제",
                            systemImage: "trash",
                            role: .destructive
                        ) {
                            deleteMemo(entry.id)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.taption(size: 10, weight: .bold))
                            .foregroundStyle(Color.tpSecondary)
                            .frame(width: 28, height: 24)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("메모 메뉴")
                }
                Text(entry.text)
                    .font(.taption(size: 11))
                    .lineSpacing(3)
                if !entry.attachments.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(entry.attachments) { attachment in
                            if attachment.kind == .photo {
                                MemoPhotoThumbnail(
                                    model: model,
                                    localIdentifier:
                                        attachment.localIdentifier
                                )
                                .frame(width: 42, height: 42)
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: 8,
                                        style: .continuous
                                    )
                                )
                            } else {
                                Button {
                                    model.toggleVoicePlayback(attachment)
                                } label: {
                                    Label(
                                        model.playingVoiceAttachmentID
                                            == attachment.id
                                            ? "정지" : "음성 재생",
                                        systemImage:
                                            model.playingVoiceAttachmentID
                                            == attachment.id
                                            ? "stop.fill" : "play.fill"
                                    )
                                    .font(
                                        .system(
                                            size: 7.5,
                                            weight: .bold
                                        )
                                    )
                                    .foregroundStyle(Color.tpSecondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 6)
                                    .background(
                                        Color.tpBackground,
                                        in: RoundedRectangle(
                                            cornerRadius: 7
                                        )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .draftCard(radius: 12)
        }
    }

    // MARK: - 입력

    private var composer: some View {
        VStack(spacing: 8) {
            TextField(
                editingMemoID == nil
                    ? "이 시각에 짧은 메모 남기기…"
                    : "메모 내용 수정…",
                text: $memo,
                axis: .vertical
            )
                .focused($composerFocused)
                .font(.taption(size: 11))
                .lineLimit(2...3)
                .padding(.horizontal, 2)
                .frame(minHeight: 40, alignment: .top)

            Rectangle()
                .fill(Color(red: 0.93, green: 0.93, blue: 0.95))
                .frame(height: 0.5)

            HStack(spacing: 7) {
                Button {
                    Task {
                        await model.toggleVoiceMemo(kind: selectedMemoKind)
                    }
                } label: {
                    memoTool(
                        model.isRecordingVoiceMemo
                            ? "stop.circle.fill" : "mic",
                        model.isRecordingVoiceMemo
                            ? "녹음 종료" : "음성"
                    )
                }
                .buttonStyle(.plain)
                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .images
                ) {
                    VStack(spacing: 2) {
                        Image(systemName: "photo")
                            .font(.taption(size: 12, weight: .semibold))
                        Text("사진")
                            .font(.taption(size: 8, weight: .bold))
                    }
                    .foregroundStyle(Color.tpSecondary)
                    .frame(width: 42, height: 34)
                    .background(
                        Color(red: 0.95, green: 0.95, blue: 0.97),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
                Spacer()
                if editingMemoID != nil {
                    Button("취소", action: cancelEditing)
                        .font(.taption(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                        .buttonStyle(.plain)
                }
                Button(action: saveMemo) {
                    memoTool(
                        editingMemoID == nil ? "plus" : "checkmark",
                        editingMemoID == nil ? "추가" : "저장",
                        dark: true
                    )
                }
                .buttonStyle(.plain)
                .disabled(
                    memo.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                )
            }
        }
        .padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(Color(red: 0.89, green: 0.89, blue: 0.91), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.07), radius: 8, y: 5)
    }

    private var entryMemos: [ActionMemo] {
        model.memoEntryMemos
    }

    private func saveMemo() {
        if let editingMemoID {
            model.updateMemo(
                editingMemoID,
                text: memo,
                kind: selectedMemoKind
            )
        } else {
            model.addMemoAtEntryInstant(text: memo, kind: selectedMemoKind)
        }
        cancelEditing()
    }

    private func beginEditing(_ entry: ActionMemo) {
        editingMemoID = entry.id
        memo = entry.text
        selectedMemoKind = entry.kind
        composerFocused = true
    }

    private func cancelEditing() {
        editingMemoID = nil
        memo = ""
        selectedMemoKind = .decision
        composerFocused = false
    }

    private func deleteMemo(_ memoID: UUID) {
        if editingMemoID == memoID {
            cancelEditing()
        }
        model.deleteMemo(memoID)
    }

    private func memoTool(_ icon: String, _ title: String, dark: Bool = false) -> some View {
        Label(title, systemImage: icon)
            .font(.taption(size: 9.5, weight: .bold))
            .foregroundStyle(dark ? Color.white : Color.tpSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(dark ? Color.tpInk : Color(red: 0.94, green: 0.94, blue: 0.95))
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

private struct MemoPhotoThumbnail: View {
    @Bindable var model: AppModel
    let localIdentifier: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.tpPhoto.opacity(0.55)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.taption(size: 13))
                    .foregroundStyle(Color.tpPhotoDark)
            }
        }
        .clipped()
        .task(id: localIdentifier) {
            guard image == nil else { return }
            guard let data = try? await model.photoThumbnailData(
                localIdentifier: localIdentifier,
                size: CGSize(width: 180, height: 180)
            ) else {
                return
            }
            image = UIImage(data: data)
        }
    }
}

struct CatPickerView: View {
    @Bindable var model: AppModel
    @State private var previewAction: TaptionWidgetCatAction = .running

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: "달리는 고양이", trailing: "완료") {
                model.detail = nil
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 9) {
                    Text("좌우 화살표로 위젯에서 사용하는 모든 고양이 동작을 미리 볼 수 있습니다.")
                        .font(.taption(size: 9))
                        .foregroundStyle(Color.tpSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)

                    VStack(spacing: 0) {
                        CatActionPreviewStage(
                            coat: model.selectedCatCoat,
                            action: previewAction,
                            reducesMotion: model.settings.reduceMotion
                        )
                        .id(previewAction)
                        .frame(height: 60)

                        HStack(spacing: 12) {
                            previewArrow(
                                systemImage: "chevron.left",
                                accessibilityLabel: "이전 동작"
                            ) {
                                movePreviewAction(by: -1)
                            }

                            VStack(spacing: 2) {
                                Label(
                                    previewAction.previewTitle,
                                    systemImage: previewAction.previewSystemImage
                                )
                                .font(.taption(size: 11, weight: .bold))
                                .foregroundStyle(Color.tpInk)
                                Text(previewPositionLabel)
                                    .font(.taption(size: 7.5, weight: .semibold))
                                    .foregroundStyle(Color.tpSecondary)
                                    .monospacedDigit()
                            }
                            .frame(maxWidth: .infinity)

                            previewArrow(
                                systemImage: "chevron.right",
                                accessibilityLabel: "다음 동작"
                            ) {
                                movePreviewAction(by: 1)
                            }
                        }
                        .padding(.top, 4)

                        Text("\(model.selectedCatCoat.rawValue) · 위젯 미리보기")
                            .font(.taption(size: 9, weight: .semibold))
                            .foregroundStyle(Color.tpSecondary)
                            .padding(.top, 7)
                        Text("선택한 모습이 홈 위젯 · 잠금 화면 · 앱에 함께 적용")
                            .font(.taption(size: 7.5))
                            .foregroundStyle(Color.tpSecondary)
                            .padding(.top, 2)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 1.00, green: 0.97, blue: 0.91),
                                Color(red: 0.94, green: 0.91, blue: 0.97),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 15)
                    )

                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 6
                    ) {
                        ForEach(CatCoat.allCases) { coat in
                            Button {
                                model.selectCatCoat(coat)
                            } label: {
                                HStack(spacing: 9) {
                                    CatFaceView(coat: coat)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(coat.rawValue)
                                            .font(.taption(size: 9.5, weight: .bold))
                                            .foregroundStyle(Color.tpInk)
                                        Text(coat.caption)
                                            .font(.taption(size: 6.8))
                                            .foregroundStyle(Color.tpSecondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, minHeight: 59)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(
                                            model.selectedCatCoat == coat ? Color.tpInk : Color(red: 0.89, green: 0.89, blue: 0.91),
                                            lineWidth: model.selectedCatCoat == coat ? 2 : 1
                                        )
                                }
                                .overlay(alignment: .topTrailing) {
                                    if model.selectedCatCoat == coat {
                                        Image(systemName: "checkmark")
                                            .font(.taption(size: 8, weight: .black))
                                            .foregroundStyle(.white)
                                            .frame(width: 15, height: 15)
                                            .background(Color.tpInk, in: Circle())
                                            .padding(5)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button {
                        model.detail = nil
                    } label: {
                        Text("\(model.selectedCatCoat.rawValue)로 적용")
                            .font(.taption(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.tpInk, in: RoundedRectangle(cornerRadius: 13))
                    }
                    .buttonStyle(.plain)

                    Label(
                        "설정에서 언제든 바꿀 수 있습니다. ‘동작 줄이기’가 켜지면 선택한 고양이가 정지 자세로 표시됩니다.",
                        systemImage: "paintpalette"
                    )
                    .font(.taption(size: 7.3))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
            }
            .background(Color.tpBackground)
        }
    }

    private var previewPositionLabel: String {
        guard let index = TaptionWidgetCatAction.allCases.firstIndex(
            of: previewAction
        ) else {
            return ""
        }
        return "\(index + 1) / \(TaptionWidgetCatAction.allCases.count)"
    }

    private func movePreviewAction(by offset: Int) {
        let actions = TaptionWidgetCatAction.allCases
        guard let index = actions.firstIndex(of: previewAction) else {
            previewAction = .running
            return
        }
        let next = (index + offset + actions.count) % actions.count
        previewAction = actions[next]
    }

    private func previewArrow(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.taption(size: 12, weight: .black))
                .foregroundStyle(Color.tpInk)
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.78), in: Circle())
                .overlay { Circle().stroke(Color.tpLine, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct InferenceDetailView: View {
    @Bindable var model: AppModel
    @State private var selectedGroupID: UUID?
    @State private var floorOverrides: [UUID: Int] = [:]
    @State private var routeReadings: [SensorReading] = []
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var routeMapViewportSize = CGSize.zero

    private let modes: [TravelMode] = [
        .walking, .running, .cycling, .bus, .subway,
        .taxi, .car, .train, .airplane, .ship,
    ]

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: "자동 추정 상세", trailing: "완료") {
                model.detail = .locationTimeline
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    Text("이동은 아래 10종류만 사용합니다. 센서가 직접 구분하지 못하는 수단은 여러 신호를 합쳐 신뢰도와 함께 표시합니다.")
                        .font(.taption(size: 9.5))
                        .foregroundStyle(Color.tpSecondary)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    routeMapCard

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 5) {
                        ForEach(modes, id: \.self) { mode in
                            Button {
                                guard let selectedGroup else { return }
                                model.confirmTravel(
                                    selectedGroup.segmentIDs,
                                    mode: mode
                                )
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: mode.systemImage)
                                        .font(.taption(size: 15))
                                    Text(mode.displayName)
                                        .font(.taption(size: 7.5, weight: .bold))
                                }
                                .foregroundStyle(
                                    selectedGroup?.mode == mode
                                        ? Color.white
                                        : Color(red: 0.40, green: 0.27, blue: 0.11)
                                )
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(
                                    selectedGroup?.mode == mode
                                        ? Color.tpTransitDark
                                        : Color.white,
                                    in: RoundedRectangle(cornerRadius: 10)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(
                                            selectedGroup?.mode == mode
                                                ? Color.tpTransitDark
                                                : Color(
                                                    red: 0.89,
                                                    green: 0.89,
                                                    blue: 0.91
                                                ),
                                            lineWidth: 1
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(selectedGroupID == nil)
                        }
                    }

                    if dayTravel.isEmpty && dayFloors.isEmpty {
                        ContentUnavailableView(
                            "확인할 추정 기록이 없습니다",
                            systemImage: "location.slash",
                            description: Text(
                                "위치·동작 센서가 이동이나 층 변화를 감지하면 여기에 나타납니다."
                            )
                        )
                        .padding(.vertical, 20)
                    } else {
                        ForEach(dayTravelGroups) { group in
                            travelInferenceCard(group)
                                .onTapGesture {
                                    selectedGroupID = group.id
                                }
                        }
                        ForEach(dayFloors) { floor in
                            floorInferenceCard(floor)
                        }
                    }

                    Label(
                        "iPhone GPS·모션·기압이 기본 · Apple Watch 운동·경로·활동 데이터는 권한을 받은 경우에만 보조",
                        systemImage: "applewatch"
                    )
                    .font(.taption(size: 7.5))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    privacyCard
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
            }
            .background(Color.tpBackground)
        }
        .onAppear {
            selectedGroupID =
                dayTravelGroups.first(where: { !$0.isConfirmed })?.id
                ?? dayTravelGroups.first?.id
            for floor in dayFloors {
                floorOverrides[floor.id] =
                    floor.toFloor ?? floor.fromFloor ?? 0
            }
        }
        .task(id: model.selectedDate) {
            routeReadings = await model.sensorReadings(in: daySpan)
            fitMapToSelection()
        }
        .onChange(of: selectedGroupID) { _, _ in
            fitMapToSelection()
        }
    }

    private func travelInferenceCard(
        _ group: TravelSegmentGroup
    ) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: group.mode.systemImage)
                    .font(.taption(size: 15))
                    .foregroundStyle(Color.tpTransitDark)
                    .frame(width: 29, height: 29)
                    .background(
                        Color.tpTransit,
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        "\(group.span.start.formatted(date: .omitted, time: .shortened))–\(group.span.end.formatted(date: .omitted, time: .shortened))"
                    )
                        .font(.taption(size: 8))
                        .foregroundStyle(Color.tpSecondary)
                    Text(
                        "\(group.mode.displayName) · \(group.span.duration.shortDuration)"
                    )
                        .font(.taption(size: 11, weight: .bold))
                }
                Spacer()
                Text(
                    group.isConfirmed
                        ? "확인됨"
                        : group.confirmedCount > 0
                            ? "일부 확인"
                            : group.confidence.displayName
                )
                    .font(.taption(size: 7.5, weight: .black))
                    .foregroundStyle(
                        group.confidence == .high
                            ? Color(red: 0.18, green: 0.46, blue: 0.28)
                            : Color(red: 0.61, green: 0.41, blue: 0.11)
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        group.confidence == .high
                            ? Color(red: 0.92, green: 0.96, blue: 0.93)
                            : Color(red: 1.00, green: 0.95, blue: 0.85),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
            }

            if group.segments.count > 1 {
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up")
                    Text("이어진 유사 경로 \(group.segments.count)개를 한 번에 표시")
                    Spacer()
                    if group.distanceMeters > 0 {
                        Text(formattedDistance(group.distanceMeters))
                    }
                }
                .font(.taption(size: 7.5, weight: .bold))
                .foregroundStyle(Color.tpTransitDark)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    Color.tpTransit.opacity(0.58),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            }

            if !group.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("판정 근거")
                        .font(.taption(size: 7.5, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                    ChipFlowLayout(spacing: 4) {
                        ForEach(group.evidence, id: \.self) { signal in
                            signalChip(signal)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                if group.isConfirmed {
                    Button("자동 판정으로 되돌리기") {
                        model.forgetTravelConfirmations(group.segmentIDs)
                    }
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        Color(red: 0.94, green: 0.94, blue: 0.95),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                } else {
                    Button("맞아요") {
                        model.confirmTravel(
                            group.segmentIDs,
                            mode: group.mode
                        )
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        Color.tpInk,
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                }
                Button("다른 수단") {
                    selectedGroupID = group.id
                }
                .foregroundStyle(Color.tpSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    Color(red: 0.94, green: 0.94, blue: 0.95),
                    in: RoundedRectangle(cornerRadius: 9)
                )
            }
            .font(.taption(size: 8.5, weight: .bold))
            .buttonStyle(.plain)
        }
        .padding(10)
        .draftCard()
        .overlay {
            if selectedGroupID == group.id {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.tpTransitDark, lineWidth: 2)
            }
        }
    }

    private func floorInferenceCard(
        _ floor: FloorTransition
    ) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "building.2")
                    .font(.taption(size: 15))
                    .foregroundStyle(Color.tpPlaceDark)
                    .frame(width: 29, height: 29)
                    .background(
                        Color.tpPlace,
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        floor.span.end.formatted(
                            date: .omitted,
                            time: .shortened
                        )
                    )
                    .font(.taption(size: 8))
                    .foregroundStyle(Color.tpSecondary)
                    Text(
                        "\(floor.fromFloor.map { "\($0)층" } ?? "기준층 미확인") → \(floorOverrides[floor.id] ?? floor.toFloor ?? 0)층"
                    )
                    .font(.taption(size: 11, weight: .bold))
                }
                Spacer()
                Text(floor.confidence.displayName)
                    .font(.taption(size: 7.5, weight: .black))
                    .foregroundStyle(
                        floor.confidence == .high
                            ? Color(red: 0.18, green: 0.46, blue: 0.28)
                            : Color(red: 0.61, green: 0.41, blue: 0.11)
                    )
            }

            ChipFlowLayout(spacing: 4) {
                ForEach(floor.evidence, id: \.self) { signal in
                    signalChip(signal)
                }
            }

            HStack(spacing: 6) {
                Button {
                    floorOverrides[floor.id, default: 0] -= 1
                } label: {
                    Image(systemName: "minus")
                }
                Text("\(floorOverrides[floor.id] ?? floor.toFloor ?? 0)층")
                    .font(.taption(size: 10, weight: .black))
                    .frame(maxWidth: .infinity)
                Button {
                    floorOverrides[floor.id, default: 0] += 1
                } label: {
                    Image(systemName: "plus")
                }
                Button("이 층으로 확인") {
                    model.confirmFloorTransition(
                        floor.id,
                        toFloor:
                            floorOverrides[floor.id]
                            ?? floor.toFloor
                    )
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Color.tpInk,
                    in: RoundedRectangle(cornerRadius: 9)
                )
            }
            .font(.taption(size: 8.5, weight: .bold))
            .buttonStyle(.plain)
        }
        .padding(10)
        .draftCard()
    }

    private func signalChip(_ signal: String) -> some View {
        Text(signal)
            .font(.taption(size: 7.5, weight: .semibold))
            .foregroundStyle(Color.tpSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                Color(red: 0.94, green: 0.94, blue: 0.95),
                in: RoundedRectangle(cornerRadius: 7)
            )
    }

    private var routeMapCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "map")
                    .foregroundStyle(Color.tpTransitDark)
                VStack(alignment: .leading, spacing: 1) {
                    Text("오늘 이동 경로")
                        .font(.taption(size: 10, weight: .bold))
                    Text("구간을 누르면 해당 경로를 강조합니다")
                        .font(.taption(size: 7.5))
                        .foregroundStyle(Color.tpSecondary)
                }
                Spacer()
                Text("\(dayTravelGroups.count)개 묶음")
                    .font(.taption(size: 7.5, weight: .bold))
                    .foregroundStyle(Color.tpTransitDark)
            }

            if allRouteCoordinates.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "location.slash")
                        .font(.taption(size: 18))
                    Text("저장된 GPS 좌표가 있는 경로부터 지도에 표시됩니다")
                        .font(.taption(size: 8, weight: .semibold))
                }
                .foregroundStyle(Color.tpSecondary)
                .frame(maxWidth: .infinity, minHeight: 105)
                .background(
                    Color.tpBackground,
                    in: RoundedRectangle(cornerRadius: 11)
                )
            } else {
                Map(position: $mapPosition, content: {
                    ForEach(dayTravelGroups) { group in
                        let coordinates = coordinates(for: group)
                        if coordinates.count >= 2 {
                            MapPolyline(coordinates: coordinates)
                                .stroke(
                                    group.mode.routeColor.opacity(
                                        selectedGroupID == group.id ? 1 : 0.42
                                    ),
                                    style: StrokeStyle(
                                        lineWidth: selectedGroupID == group.id ? 5 : 3,
                                        lineCap: .round,
                                        lineJoin: .round
                                    )
                                )
                        }
                    }
                    if let group = selectedGroup,
                       let start = coordinates(for: group).first {
                        Marker("출발", systemImage: "circle.fill", coordinate: start)
                            .tint(group.mode.routeColor)
                    }
                    if let group = selectedGroup,
                       let end = coordinates(for: group).last,
                       coordinates(for: group).count >= 2 {
                        Marker("도착", systemImage: "mappin", coordinate: end)
                            .tint(group.mode.routeColor)
                    }
                })
                .mapStyle(.standard)
                .frame(height: 165)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear {
                                updateRouteMapViewportSize(geometry.size)
                            }
                            .onChange(of: geometry.size) { _, size in
                                updateRouteMapViewportSize(size)
                            }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 11))
            }

            HStack(spacing: 7) {
                if let selectedGroup {
                    Label(
                        "\(selectedGroup.mode.displayName) · \(selectedGroup.span.duration.shortDuration)",
                        systemImage: selectedGroup.mode.systemImage
                    )
                    .font(.taption(size: 8, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                    .lineLimit(1)
                } else {
                    Text("경로를 선택해 주세요")
                        .font(.taption(size: 8))
                        .foregroundStyle(Color.tpSecondary)
                }
                Spacer()
                Button {
                    guard let selectedGroup else { return }
                    openInAppleMaps(selectedGroup)
                } label: {
                    Label("Apple 지도", systemImage: "arrow.up.right.square")
                        .font(.taption(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            Color.tpInk,
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                }
                .buttonStyle(.plain)
                .disabled(
                    selectedGroup.map { coordinates(for: $0).isEmpty }
                        ?? true
                )
                .opacity(
                    selectedGroup.map { coordinates(for: $0).isEmpty }
                        == false ? 1 : 0.42
                )
            }
        }
        .padding(9)
        .draftCard()
    }

    private var allRouteCoordinates: [CLLocationCoordinate2D] {
        dayTravelGroups.flatMap(coordinates(for:))
    }

    private func routePoints(for group: TravelSegmentGroup) -> [GeoPoint] {
        var points: [GeoPoint] = []
        if let fromPlaceID = group.fromPlaceID,
           let point = model.snapshot.places.first(where: {
               $0.id == fromPlaceID
           })?.point {
            points.append(point)
        }
        points.append(contentsOf: model.mergingLiveSensorReadings(
            routeReadings,
            in: daySpan
        )
            .filter { group.span.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap(\.point)
            .filter { $0.horizontalAccuracy <= 200 }
        )
        if let toPlaceID = group.toPlaceID,
           let point = model.snapshot.places.first(where: {
               $0.id == toPlaceID
           })?.point {
            points.append(point)
        }

        return points.reduce(into: []) { result, point in
            guard let previous = result.last else {
                result.append(point)
                return
            }
            if distanceMeters(previous, point) >= 8 {
                result.append(point)
            }
        }
    }

    private func coordinates(
        for group: TravelSegmentGroup
    ) -> [CLLocationCoordinate2D] {
        routePoints(for: group).map {
            CLLocationCoordinate2D(
                latitude: $0.latitude,
                longitude: $0.longitude
            )
        }
    }

    private func fitMapToSelection() {
        let values: [CLLocationCoordinate2D]
        if let selectedGroup {
            values = coordinates(for: selectedGroup)
        } else {
            values = allRouteCoordinates
        }
        guard let region = RouteMapViewport.region(
            for: values,
            viewport: resolvedRouteMapViewportSize,
            padding: .compact
        ) else {
            mapPosition = .automatic
            return
        }
        mapPosition = .region(region)
    }

    private var resolvedRouteMapViewportSize: CGSize {
        guard routeMapViewportSize.width > 1,
              routeMapViewportSize.height > 1 else {
            return CGSize(width: 340, height: 165)
        }
        return routeMapViewportSize
    }

    private func updateRouteMapViewportSize(_ size: CGSize) {
        guard size.width > 1,
              size.height > 1,
              abs(routeMapViewportSize.width - size.width) > 0.5
                || abs(routeMapViewportSize.height - size.height) > 0.5
        else { return }
        routeMapViewportSize = size
        fitMapToSelection()
    }

    private func openInAppleMaps(_ group: TravelSegmentGroup) {
        let values = coordinates(for: group)
        guard let first = values.first else { return }
        let start = MKMapItem(placemark: MKPlacemark(coordinate: first))
        start.name = model.snapshot.places.first(where: {
            $0.id == group.fromPlaceID
        })?.displayName ?? "출발"

        guard values.count >= 2, let last = values.last else {
            start.openInMaps()
            return
        }
        let destination = MKMapItem(
            placemark: MKPlacemark(coordinate: last)
        )
        destination.name = model.snapshot.places.first(where: {
            $0.id == group.toPlaceID
        })?.displayName ?? "도착"
        var options: [String: Any] = [:]
        if let directionMode = group.mode.appleMapsDirectionsMode {
            options[MKLaunchOptionsDirectionsModeKey] = directionMode
        }
        if group.mode == .car || group.mode == .taxi || group.mode == .bus {
            options[MKLaunchOptionsShowsTrafficKey] = true
        }
        MKMapItem.openMaps(
            with: [start, destination],
            launchOptions: options
        )
    }

    private func formattedDistance(_ meters: Double) -> String {
        if meters >= 1_000 {
            return String(format: "%.1fkm", meters / 1_000)
        }
        return "\(Int(meters.rounded()))m"
    }

    private var daySpan: TimeSpan {
        TimelineAggregationEngine().interval(
            for: .day,
            containing: model.selectedDate
        )
    }

    private var dayTravel: [TravelSegment] {
        model.snapshot.travel
            .filter { $0.span.intersection(with: daySpan) != nil }
            .sorted { $0.span.start < $1.span.start }
    }

    private var dayTravelGroups: [TravelSegmentGroup] {
        TravelSegmentGroupingEngine.groups(from: dayTravel)
    }

    private var dayFloors: [FloorTransition] {
        model.snapshot.floorTransitions
            .filter { $0.span.intersection(with: daySpan) != nil }
            .sorted { $0.span.start < $1.span.start }
    }

    private var selectedGroup: TravelSegmentGroup? {
        guard let selectedGroupID else { return nil }
        return dayTravelGroups.first { $0.id == selectedGroupID }
    }

    private var privacyCard: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock")
                .font(.taption(size: 15))
                .foregroundStyle(Color.tpPlaceDark)
            VStack(alignment: .leading, spacing: 2) {
                Text("모르면 확정하지 않음")
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text("‘차량 추정’ 또는 ‘층 미확인’으로 남기고 한 번 탭해 수정")
                    .font(.taption(size: 8))
                    .foregroundStyle(Color.tpSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color(red: 0.89, green: 0.89, blue: 0.91), lineWidth: 1)
        }
    }
}

struct LocationTimelineView: View {
    @Bindable var model: AppModel
    @State private var viewportStart: CGFloat = 0
    @State private var viewportLength: CGFloat = 1
    @State private var dragStart: CGFloat?
    @State private var magnifyStart: (
        start: CGFloat,
        length: CGFloat
    )?

    var body: some View {
        VStack(spacing: 0) {
            DraftTopBar(
                title: model.selectedDate.formatted(
                    Date.FormatStyle()
                        .month(.defaultDigits)
                        .day(.defaultDigits)
                        .weekday(.wide)
                        .locale(Locale(identifier: "ko_KR"))
                ),
                trailing: "\(Calendar.autoupdatingCurrent.component(.year, from: model.selectedDate))",
                selectedScale: .day,
                onScaleChange: {
                    model.selectScale($0)
                    model.detail = nil
                }
            )

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Button {
                        model.detail = .inference
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "mappin.and.ellipse")
                                .foregroundStyle(Color(red: 0.18, green: 0.54, blue: 0.36))
                            Text(locationStatusTitle)
                                .fontWeight(.bold)
                            Spacer()
                            Text(
                                model.currentAltitudeStatus
                                    ?? sensorSignalLabel
                            )
                                .font(.taption(size: 9.5))
                                .foregroundStyle(Color.tpSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .font(.taption(size: 10.5))
                        .foregroundStyle(Color(red: 0.14, green: 0.37, blue: 0.49))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            Color(red: 0.93, green: 0.97, blue: 0.98),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.top, 9)
                    .padding(.bottom, 7)

                    compactTimeAxis

                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            placeRow
                            moveRow
                            projectRow
                        }
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            currentLocationLine(at: context.date)
                        }
                    }
                    .frame(height: 208)
                    .clipped()
                    .overlay {
                        GeometryReader { proxy in
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(
                                    viewportDragGesture(
                                        width: max(
                                            1,
                                            proxy.size.width - 50
                                        )
                                    )
                                )
                                .simultaneousGesture(
                                    viewportMagnifyGesture
                                )
                        }
                    }

                    routeDock
                        .padding(.horizontal, 8)
                        .padding(.top, 9)

                    HStack(spacing: 6) {
                        Image(systemName: "lock")
                            .font(.taption(size: 15))
                            .foregroundStyle(Color.tpPlaceDark)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("센서 결과는 신뢰도와 함께 기기 안에서 정리")
                                .font(.taption(size: 9, weight: .bold))
                                .foregroundStyle(Color.tpInk)
                            Text("정확한 주소·원시 좌표는 기본 타임라인에 표시하지 않음")
                                .font(.taption(size: 8))
                        }
                    }
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 11))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(Color(red: 0.89, green: 0.89, blue: 0.91), lineWidth: 1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
            .background(Color.white)
        }
        .task(id: model.selectedDate) {
            await model.refreshSensorTimeline()
        }
    }

    private var compactTimeAxis: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 50)
            ForEach(viewportTickDates, id: \.self) { date in
                Text(viewportTickLabel(date))
                    .font(.taption(size: 10))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine).frame(height: 0.5) }
    }

    private var placeRow: some View {
        HStack(spacing: 0) {
            rowLabel("위치", color: .tpPlaceDark)
            GeometryReader { proxy in
                ForEach(dayPlaces) { place in
                    let range = fractionRange(place.span)
                    locationBar(
                        placeLabel(place),
                        range.lowerBound,
                        range.upperBound - range.lowerBound,
                        proxy
                    )
                }
                ForEach(dayFloors) { floor in
                    floorMarker(floor, proxy: proxy)
                }
                if dayPlaces.isEmpty {
                    emptyRowText("머문 장소를 감지하면 여기에 표시됩니다")
                }
            }
        }
        .frame(height: 78)
        .background(Color(red: 0.98, green: 0.99, blue: 1.00))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine.opacity(0.5)).frame(height: 0.5) }
    }

    private var moveRow: some View {
        HStack(spacing: 0) {
            rowLabel("이동", color: .tpTransitDark)
            GeometryReader { proxy in
                ForEach(dayTravel) { travel in
                    let range = fractionRange(travel.span)
                    moveBar(
                        travel.mode.systemImage,
                        range.lowerBound,
                        range.upperBound - range.lowerBound,
                        proxy,
                        dashed: travel.confidence == .low
                    )
                }
                if dayTravel.isEmpty {
                    emptyRowText("위치 사이 이동을 자동으로 분류합니다")
                }
            }
        }
        .frame(height: 70)
        .background(Color(red: 1.00, green: 0.99, blue: 0.97))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine.opacity(0.5)).frame(height: 0.5) }
    }

    private var projectRow: some View {
        HStack(spacing: 0) {
            rowLabel("프로젝트", color: .tpProjectDark, compact: true)
            GeometryReader { proxy in
                ForEach(dayPlans) { plan in
                    let range = fractionRange(plan.span)
                    simpleBar(
                        plan.title,
                        start: range.lowerBound,
                        length: range.upperBound - range.lowerBound,
                        proxy: proxy
                    )
                }
                if dayPlans.isEmpty {
                    emptyRowText("같은 시간의 계획이 함께 표시됩니다")
                }
            }
        }
        .frame(height: 60)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine.opacity(0.5)).frame(height: 0.5) }
    }

    @ViewBuilder
    private func currentLocationLine(at date: Date) -> some View {
        if visibleTimelineSpan.contains(date) {
        GeometryReader { proxy in
            let x = 50 + max(1, proxy.size.width - 50)
                * fraction(for: date)
            Rectangle()
                .fill(Color.tpNow)
                .frame(width: 2, height: proxy.size.height)
                .position(x: x, y: proxy.size.height / 2)
            Text(date.formatted(date: .omitted, time: .shortened))
                .font(.taption(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.tpNow, in: Capsule())
                .position(x: x, y: 7)
        }
        }
    }

    private var routeDock: some View {
        VStack(spacing: 0) {
            HStack {
                Text("오늘 움직인 경로")
                    .font(.taption(size: 10.5, weight: .bold))
                Spacer()
                HStack(spacing: 3) {
                    Circle().fill(Color(red: 0.27, green: 0.83, blue: 0.51)).frame(width: 5, height: 5)
                    Text("위 시간축과 실시간 동기화")
                }
                .font(.taption(size: 7.5))
                .foregroundStyle(Color(red: 0.56, green: 0.94, blue: 0.72))
            }
            .padding(.bottom, 4)

            HStack {
                ForEach(viewportTickDates, id: \.self) { date in
                    Text(viewportTickLabel(date))
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                }
            }
            .font(.taption(size: 6))
            .foregroundStyle(Color(red: 0.41, green: 0.41, blue: 0.44))

            GeometryReader { proxy in
                Rectangle()
                    .fill(Color(red: 0.27, green: 0.27, blue: 0.29))
                    .frame(height: 1)
                    .position(x: proxy.size.width / 2, y: 28)

                ForEach(dayPlaces) { place in
                    let range = fractionRange(place.span)
                    routeSegment(
                        .tpPlaceDark,
                        range.lowerBound,
                        range.upperBound - range.lowerBound,
                        proxy
                    )
                    routeNode(
                        "\(placeLabel(place))\n\(place.span.end.formatted(date: .omitted, time: .shortened))",
                        range.upperBound,
                        above: dayPlaces.firstIndex(where: {
                            $0.id == place.id
                        })?.isMultiple(of: 2) ?? true,
                        proxy
                    )
                }
                ForEach(dayTravel) { travel in
                    let range = fractionRange(travel.span)
                    routeSegment(
                        travel.mode.routeColor,
                        range.lowerBound,
                        range.upperBound - range.lowerBound,
                        proxy,
                        dashed: travel.confidence == .low
                    )
                }
                ForEach(dayFloors) { floor in
                    let point = fraction(for: floor.span.end)
                    Text(floor.floorChangeLabel)
                        .font(.taption(size: 6, weight: .black))
                        .foregroundStyle(.white)
                        .position(x: proxy.size.width * point, y: 47)
                }

                if dayPlaces.isEmpty && dayTravel.isEmpty {
                    Text("오늘의 위치·이동 기록이 아직 없습니다")
                        .font(.taption(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .position(
                            x: proxy.size.width / 2,
                            y: 28
                        )
                }

                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if visibleTimelineSpan.contains(context.date) {
                        let current = fraction(for: context.date)
                        Rectangle()
                            .fill(Color.tpNow)
                            .frame(width: 2, height: 49)
                            .position(
                                x: proxy.size.width * current,
                                y: 31
                            )
                        Circle()
                            .fill(Color.tpNow)
                            .frame(width: 12, height: 12)
                            .position(
                                x: proxy.size.width * current,
                                y: 28
                            )
                        Text(
                            context.date.formatted(
                                date: .omitted,
                                time: .shortened
                            )
                        )
                        .font(.taption(size: 6, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            Color.tpNow,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .position(
                            x: min(
                                proxy.size.width - 23,
                                max(23, proxy.size.width * current)
                            ),
                            y: 7
                        )
                    }
                }
            }
            .frame(height: 62)
            .clipped()
            .overlay {
                GeometryReader { proxy in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            viewportDragGesture(
                                width: max(1, proxy.size.width)
                            )
                        )
                        .simultaneousGesture(viewportMagnifyGesture)
                }
            }

            HStack {
                Text("길이 = 실제 시간 · 빨간 선 = 현재")
                Spacer()
                Button {
                    followNow()
                } label: {
                    Text(
                        viewportLength < 0.999
                            ? "지금으로"
                            : "밀기·핀치로 함께 탐색"
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    Color(red: 0.78, green: 0.78, blue: 0.80)
                )
            }
            .font(.taption(size: 6.8))
            .foregroundStyle(Color(red: 0.56, green: 0.56, blue: 0.58))
            .padding(.top, 6)
            .overlay(alignment: .top) {
                Rectangle().fill(Color(red: 0.19, green: 0.19, blue: 0.21)).frame(height: 0.5)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 10)
        .background(Color(red: 0.09, green: 0.09, blue: 0.10), in: RoundedRectangle(cornerRadius: 15))
        .shadow(color: .black.opacity(0.16), radius: 9, y: 6)
    }

    private func rowLabel(_ title: String, color: Color, compact: Bool = false) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 8, height: 8)
            Text(title)
                .font(.taption(size: compact ? 9 : 10.5, weight: .semibold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .padding(.leading, compact ? 4 : 8)
        .frame(width: 50, alignment: .leading)
    }

    private func locationBar(_ title: String, _ start: CGFloat, _ length: CGFloat, _ proxy: GeometryProxy) -> some View {
        Text(title)
            .font(.taption(size: 9.5, weight: .black))
            .foregroundStyle(Color(red: 0.14, green: 0.37, blue: 0.49))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: max(17, proxy.size.width * length), height: 32)
            .background(Color.tpPlace, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(Color.tpPlaceDark.opacity(0.35)) }
            .position(x: proxy.size.width * start + max(17, proxy.size.width * length) / 2, y: 31)
    }

    private func moveBar(_ icon: String, _ start: CGFloat, _ length: CGFloat, _ proxy: GeometryProxy, dashed: Bool = false) -> some View {
        Image(systemName: icon)
            .font(.taption(size: 11))
            .foregroundStyle(Color(red: 0.44, green: 0.29, blue: 0.09))
            .frame(width: max(14, proxy.size.width * length), height: 29)
            .background(Color.tpTransit.opacity(dashed ? 0.68 : 1), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.tpTransitDark.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : []))
            }
            .position(x: proxy.size.width * start + max(14, proxy.size.width * length) / 2, y: 32)
    }

    private func simpleBar(_ title: String, start: CGFloat, length: CGFloat, proxy: GeometryProxy) -> some View {
        Text(title)
            .font(.taption(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.tpInk.opacity(0.64))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(width: max(18, proxy.size.width * length), height: 26, alignment: .leading)
            .background(Color.tpProject, in: RoundedRectangle(cornerRadius: 7))
            .position(x: proxy.size.width * start + max(18, proxy.size.width * length) / 2, y: 29)
    }

    private func routeSegment(
        _ color: Color,
        _ start: CGFloat,
        _ length: CGFloat,
        _ proxy: GeometryProxy,
        dashed: Bool = false
    ) -> some View {
        Capsule()
            .fill(color.opacity(dashed ? 0.48 : 1))
            .frame(width: max(2, proxy.size.width * length), height: 7)
            .overlay {
                if dashed {
                    Capsule().stroke(
                        .white.opacity(0.65),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                    )
                }
            }
            .position(x: proxy.size.width * start + max(2, proxy.size.width * length) / 2, y: 28)
    }

    private func routeNode(_ title: String, _ position: CGFloat, above: Bool, _ proxy: GeometryProxy) -> some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.09, green: 0.09, blue: 0.10))
                .overlay { Circle().stroke(.white, lineWidth: 2) }
                .frame(width: 11, height: 11)
            Text(title)
                .font(.taption(size: 6))
                .multilineTextAlignment(.center)
                .fixedSize()
                .offset(y: above ? -19 : 19)
        }
        .position(x: proxy.size.width * position, y: 28)
    }

    private var daySpan: TimeSpan {
        TimelineAggregationEngine().interval(
            for: .day,
            containing: model.selectedDate
        )
    }

    private var dayPlaces: [PlaceStay] {
        model.snapshot.places
            .filter {
                $0.span.intersection(with: visibleTimelineSpan) != nil
            }
            .sorted { $0.span.start < $1.span.start }
    }

    private var dayTravel: [TravelSegment] {
        model.snapshot.travel
            .filter {
                $0.span.intersection(with: visibleTimelineSpan) != nil
            }
            .sorted { $0.span.start < $1.span.start }
    }

    private var dayFloors: [FloorTransition] {
        model.snapshot.floorTransitions
            .filter {
                $0.span.intersection(with: visibleTimelineSpan) != nil
            }
            .sorted { $0.span.start < $1.span.start }
    }

    private var dayPlans: [PlanRecord] {
        model.snapshot.plans
            .filter {
                $0.span.intersection(with: visibleTimelineSpan) != nil
            }
            .sorted { $0.span.start < $1.span.start }
    }

    private var locationStatusTitle: String {
        if model.isSensorCollecting { return "위치·이동 기록 중" }
        if model.settings.locationEnabled { return "위치·이동 대기 중" }
        return "위치·이동 연결 필요"
    }

    private var sensorSignalLabel: String {
        guard let availability = model.sensorAvailability else {
            return "GPS · 모션 · 기압 · Watch"
        }
        var values: [String] = []
        if availability.location { values.append("GPS") }
        if availability.motionActivity { values.append("모션") }
        if availability.relativeAltitude { values.append("기압") }
        if model.settings.healthEnabled { values.append("Watch") }
        return values.isEmpty ? "센서 확인 필요" : values.joined(separator: " · ")
    }

    private func placeLabel(_ place: PlaceStay) -> String {
        var values = [place.displayName]
        if let floor = place.floor {
            values.append("\(floor)F")
        }
        if let point = place.point {
            values.append("해발 \(Int(point.altitude.rounded()))m")
        }
        return values.joined(separator: "·")
    }

    private func fraction(for date: Date) -> CGFloat {
        max(
            0,
            min(
                1,
                CGFloat(
                    date.timeIntervalSince(visibleTimelineSpan.start)
                        / max(1, visibleTimelineSpan.duration)
                )
            )
        )
    }

    private func fractionRange(_ span: TimeSpan) -> ClosedRange<CGFloat> {
        let overlap = span.intersection(with: visibleTimelineSpan)
            ?? span
        return fraction(for: overlap.start)...fraction(for: overlap.end)
    }

    private var visibleTimelineSpan: TimeSpan {
        TimeSpan(
            start: daySpan.start.addingTimeInterval(
                daySpan.duration * TimeInterval(viewportStart)
            ),
            end: daySpan.start.addingTimeInterval(
                daySpan.duration
                    * TimeInterval(viewportStart + viewportLength)
            )
        )
    }

    private var viewportTickDates: [Date] {
        (0..<6).map { index in
            visibleTimelineSpan.start.addingTimeInterval(
                visibleTimelineSpan.duration
                    * TimeInterval(index) / 6
            )
        }
    }

    private func viewportTickLabel(_ date: Date) -> String {
        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.hour, .minute],
            from: date
        )
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        if viewportLength >= 0.5 || minute == 0 {
            return String(format: "%02d", hour)
        }
        return String(format: "%02d:%02d", hour, minute)
    }

    private func viewportDragGesture(
        width: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = viewportStart
                }
                let origin = dragStart ?? viewportStart
                viewportStart = clampedViewportStart(
                    origin
                        - value.translation.width
                        / max(1, width)
                        * viewportLength,
                    length: viewportLength
                )
            }
            .onEnded { _ in
                dragStart = nil
            }
    }

    private var viewportMagnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if magnifyStart == nil {
                    magnifyStart = (viewportStart, viewportLength)
                }
                guard let origin = magnifyStart else { return }
                let newLength = max(
                    0.125,
                    min(1, origin.length / value.magnification)
                )
                let center = origin.start + origin.length / 2
                viewportLength = newLength
                viewportStart = clampedViewportStart(
                    center - newLength / 2,
                    length: newLength
                )
            }
            .onEnded { _ in
                magnifyStart = nil
            }
    }

    private func clampedViewportStart(
        _ value: CGFloat,
        length: CGFloat
    ) -> CGFloat {
        max(0, min(1 - length, value))
    }

    private func followNow() {
        guard daySpan.contains(.now) else {
            viewportStart = 0
            viewportLength = 1
            return
        }
        if viewportLength >= 0.999 {
            viewportStart = 0
            return
        }
        let nowFraction = CGFloat(
            Date.now.timeIntervalSince(daySpan.start)
                / max(1, daySpan.duration)
        )
        withAnimation(.easeOut(duration: 0.22)) {
            viewportStart = clampedViewportStart(
                nowFraction - viewportLength * 0.65,
                length: viewportLength
            )
        }
    }

    private func floorMarker(
        _ floor: FloorTransition,
        proxy: GeometryProxy
    ) -> some View {
        let x = proxy.size.width * fraction(for: floor.span.end)
        return ZStack {
            Rectangle()
                .fill(Color.tpPlaceDark)
                .frame(width: 2, height: 64)
            Text(floor.floorChangeLabel)
                .font(.taption(size: 6.5, weight: .black))
                .foregroundStyle(Color.tpPlaceDark)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.white, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.tpPlaceDark.opacity(0.35))
                }
                .offset(y: -25)
        }
        .position(x: x, y: 39)
    }

    private func emptyRowText(_ text: String) -> some View {
        Text(text)
            .font(.taption(size: 8.5))
            .foregroundStyle(Color.tpSecondary.opacity(0.72))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WidgetPreviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: "위젯 미리보기", trailing: "완료") {
                model.detail = nil
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("홈 화면 · 중간 위젯")
                        .font(.taption(size: 12, weight: .bold))
                        .foregroundStyle(Color.tpInk.opacity(0.55))
                        .padding(.horizontal, 4)

                    widgetCard

                    Text("잠금 화면 · 현재 활동")
                        .font(.taption(size: 12, weight: .bold))
                        .foregroundStyle(Color.tpInk.opacity(0.55))
                        .padding(.horizontal, 4)
                        .padding(.top, 12)

                    liveCard
                }
                .padding(14)
            }
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.86, green: 0.91, blue: 0.96),
                        Color(red: 0.93, green: 0.90, blue: 0.95),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private var widgetCard: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 5) {
                    Text("지금의 시간표")
                        .font(.taption(size: 13, weight: .bold))
                    Text("집중 중")
                        .font(.taption(size: 8, weight: .bold))
                        .foregroundStyle(Color(red: 0.57, green: 0.38, blue: 0.08))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(red: 1.00, green: 0.95, blue: 0.85), in: Capsule())
                    Text("\(model.selectedCatCoat.shortName) ▾")
                        .font(.taption(size: 8, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white, in: Capsule())
                        .overlay { Capsule().stroke(Color.tpLine) }
                }
                Spacer()
                Label(widgetTrailingLabel, systemImage: weatherSymbol)
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpWeatherDark)
            }
            .padding(.bottom, 10)

            GeometryReader { proxy in
                let now = widgetFraction(Date.now)
                Rectangle().fill(Color.tpLine).frame(height: 0.5).position(x: proxy.size.width / 2, y: 0)
                RunningCatView(coat: model.selectedCatCoat)
                    .position(x: proxy.size.width * now, y: 19)
                ForEach(Array(widgetPlans.prefix(2).enumerated()), id: \.element.id) { index, plan in
                    let start = widgetFraction(plan.span.start)
                    let end = widgetFraction(plan.span.end)
                    let width = max(
                        20,
                        proxy.size.width * max(0.02, end - start)
                    )
                    RoundedRectangle(cornerRadius: 7)
                        .fill(categoryColor(plan.categoryID))
                        .frame(width: width, height: 24)
                        .overlay(alignment: .leading) {
                            Text(plan.title)
                                .font(.taption(size: 9.5, weight: .semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                        }
                        .position(
                            x: proxy.size.width * start + width / 2,
                            y: 45 + CGFloat(index * 27)
                        )
                }
                Rectangle().fill(Color.tpNow).frame(width: 2, height: 42)
                    .position(x: proxy.size.width * now, y: 55)
            }
            .frame(height: 112)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine).frame(height: 0.5) }
        }
        .padding(14)
        .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 8)
    }

    private func widgetAction(
        _ icon: String,
        _ title: String,
        action: WidgetAction
    ) -> some View {
        Button {
            guard let planID = activeWidgetPlan?.id else { return }
            Task {
                await model.performQuickAction(action, planID: planID)
            }
        } label: {
            Label(title, systemImage: icon)
                .font(.taption(size: 10, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    Color(red: 0.93, green: 0.93, blue: 0.94),
                    in: RoundedRectangle(cornerRadius: 10)
                )
        }
        .buttonStyle(.plain)
        .disabled(activeWidgetPlan == nil)
    }

    private var liveCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text(activeWidgetPlan?.title ?? "현재 실행 중인 계획 없음")
                    .font(.taption(size: 13, weight: .bold))
                Spacer()
                if let plan = activeWidgetPlan {
                    Text(
                        plan.span.end,
                        style: .relative
                    )
                    .font(.taption(size: 11))
                    .foregroundStyle(
                        Color(red: 0.78, green: 0.78, blue: 0.80)
                    )
                }
            }
            GeometryReader { proxy in
                Capsule().fill(Color(red: 0.21, green: 0.21, blue: 0.23))
                Capsule()
                    .fill(Color.tpStudyDark)
                    .frame(
                        width: proxy.size.width
                            * activeProgress
                    )
            }
            .frame(height: 6)
            .padding(.vertical, 13)
            HStack {
                Text(activeTimeLabel).font(.taption(size: 11))
                Spacer()
                if let planID = activeWidgetPlan?.id {
                    Button("종료") {
                        Task {
                            await model.performQuickAction(
                                .stopCurrentActivity,
                                planID: planID
                            )
                        }
                    }
                    .font(.taption(size: 11, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(
                        .white,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .buttonStyle(.plain)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(Color(red: 0.08, green: 0.08, blue: 0.09), in: RoundedRectangle(cornerRadius: 18))
    }

    private var widgetDaySpan: TimeSpan {
        TimelineAggregationEngine().interval(
            for: .day,
            containing: .now
        )
    }

    private var widgetPlans: [PlanRecord] {
        model.snapshot.plans
            .filter {
                $0.status != .skipped
                    && $0.span.intersection(with: widgetDaySpan) != nil
            }
            .sorted { $0.span.start < $1.span.start }
    }

    private var activeWidgetPlan: PlanRecord? {
        widgetPlans.first {
            $0.status == .running || $0.span.contains(.now)
        } ?? widgetPlans.first { $0.span.start > .now }
    }

    private func widgetFraction(_ date: Date) -> CGFloat {
        max(
            0,
            min(
                1,
                CGFloat(
                    date.timeIntervalSince(widgetDaySpan.start)
                        / max(1, widgetDaySpan.duration)
                )
            )
        )
    }

    private func categoryColor(_ id: String) -> Color {
        guard let category = model.snapshot.categories.first(where: {
            $0.id == id
        }) else {
            return .tpProject
        }
        return Color(hex: category.lightHex)
    }

    private var activeProgress: CGFloat {
        guard let plan = activeWidgetPlan, plan.span.duration > 0 else {
            return 0
        }
        return max(
            0,
            min(
                1,
                CGFloat(
                    Date.now.timeIntervalSince(plan.span.start)
                        / plan.span.duration
                )
            )
        )
    }

    private var activeTimeLabel: String {
        guard let plan = activeWidgetPlan else {
            return "계획을 시작하면 잠금 화면에 표시됩니다"
        }
        return "\(plan.span.start.formatted(date: .omitted, time: .shortened)) → \(plan.span.end.formatted(date: .omitted, time: .shortened))"
    }

    private var currentWeather: WeatherContext? {
        model.snapshot.weather.min {
            abs($0.observedAt.timeIntervalSinceNow)
                < abs($1.observedAt.timeIntervalSinceNow)
        }
    }

    private var widgetTrailingLabel: String {
        let time = Date.now.formatted(date: .omitted, time: .shortened)
        guard let currentWeather else { return time }
        return "\(currentWeather.temperatureCelsius.rounded().formatted())° · \(time)"
    }

    private var weatherSymbol: String {
        currentWeather?.symbolName ?? "clock"
    }
}


struct CategorySetupView: View {
    @Bindable var model: AppModel

    private let automaticIDs: Set<String> = [
        "movement", "location", "activity", "sleep", "photo"
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("닫기") { model.cancelInitialCategorySelection() }
                    .font(.taption(size: 11, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                Spacer()
                Text("시작 구성")
                    .font(.taption(size: 13, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Spacer()
                Button("저장") {
                    Task { await model.applyInitialCategorySelection() }
                }
                .font(.taption(size: 11, weight: .bold))
                .foregroundStyle(
                    model.selectedSetupCategoryCount > 0
                        ? Color.tpInk
                        : Color.tpSecondary.opacity(0.35)
                )
                .disabled(model.selectedSetupCategoryCount == 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.tpLine).frame(height: 0.5)
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("필요한 일과만 골라보세요")
                        .font(.taption(size: 21, weight: .bold))
                    Text("역할·상황·루틴에 맞는 항목을 시간표와 추가 메뉴에 표시합니다. 자동 기록 항목도 여기서 켜고 끌 수 있습니다.")
                        .font(.taption(size: 10.5))
                        .foregroundStyle(Color.tpSecondary)

                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 8
                    ) {
                        ForEach(model.setupCategories) { category in
                            categoryCard(category)
                        }
                    }

                    Text("선택 \(model.selectedSetupCategoryCount)개 · 분류표 관리에서 자동 분류 기준을 확인할 수 있습니다.")
                        .font(.taption(size: 9, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                        .padding(.top, 2)

                    Button {
                        model.cancelInitialCategorySelection()
                        model.selectedTab = .settings
                    } label: {
                        Label("자주가는 곳 설정", systemImage: "star.circle.fill")
                            .font(.taption(size: 9.5, weight: .bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.tpPlaceDark)
                }
                .padding(14)
            }
            .background(Color.tpBackground)
        }
        .background(Color.tpBackground)
    }

    private func categoryCard(_ category: CategoryDefinition) -> some View {
        let selected = model.pendingSetupCategoryIDs.contains(category.id)
        let tint = Color(hex: category.darkHex)
        return Button {
            model.toggleSetupCategory(category.id)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: category.icon.systemImage)
                        .font(.taption(size: 16, weight: .bold))
                        .foregroundStyle(tint)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.taption(size: 15, weight: .bold))
                        .foregroundStyle(selected ? tint : Color.tpLine)
                }
                Text(category.name)
                    .font(.taption(size: 11, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                    .lineLimit(1)
                Text(automaticIDs.contains(category.id) ? "자동 기록" : category.isBuiltIn ? "기본 대분류" : "직접 추가")
                    .font(.taption(size: 8, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
            .background(
                selected ? Color(hex: category.lightHex).opacity(0.75) : Color.white,
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(selected ? tint.opacity(0.65) : Color.tpLine, lineWidth: selected ? 1.5 : 0.8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("대분류 \(category.name)")
        .accessibilityValue(selected ? "선택됨" : "선택 안 됨")
    }
}

private struct DetailHeader: View {
    let title: String
    let trailing: String
    var trailingColor: Color = .tpSecondary
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.taption(size: 19, weight: .bold))
                .foregroundStyle(Color.tpInk)
            Spacer()
            Button(trailing, action: action)
                .font(.taption(size: 12, weight: .bold))
                .foregroundStyle(trailingColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(Color.white)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine).frame(height: 0.5) }
    }
}

private extension MemoKind {
    var displayName: String {
        switch self {
        case .decision: "결정"
        case .idea: "아이디어"
        case .blocker: "막힘"
        case .nextAction: "다음 할 일"
        }
    }
}

private extension TravelMode {
    var systemImage: String {
        switch self {
        case .walking: "figure.walk"
        case .running: "figure.run"
        case .cycling: "bicycle"
        case .bus: "bus"
        case .subway: "tram"
        case .taxi: "car.side"
        case .car: "car"
        case .train: "train.side.front.car"
        case .airplane: "airplane"
        case .ship: "ferry"
        }
    }

    var displayName: String {
        switch self {
        case .walking: "걷기"
        case .running: "달리기"
        case .cycling: "자전거"
        case .bus: "버스"
        case .subway: "지하철"
        case .taxi: "택시"
        case .car: "자동차"
        case .train: "기차"
        case .airplane: "비행기"
        case .ship: "배"
        }
    }

    var routeColor: Color {
        switch self {
        case .walking, .running, .cycling:
            Color.tpTransitDark
        case .bus, .taxi, .car:
            Color(red: 0.95, green: 0.77, blue: 0.44)
        case .subway, .train:
            Color(red: 0.56, green: 0.79, blue: 0.90)
        case .airplane:
            Color(red: 0.72, green: 0.66, blue: 0.92)
        case .ship:
            Color(red: 0.34, green: 0.67, blue: 0.76)
        }
    }

    var appleMapsDirectionsMode: String? {
        switch self {
        case .walking, .running:
            MKLaunchOptionsDirectionsModeWalking
        case .cycling:
            MKLaunchOptionsDirectionsModeCycling
        case .bus, .subway, .train:
            MKLaunchOptionsDirectionsModeTransit
        case .taxi, .car:
            MKLaunchOptionsDirectionsModeDriving
        case .airplane, .ship:
            nil
        }
    }
}

private extension FloorTransition {
    var floorChangeLabel: String {
        if let fromFloor, let toFloor {
            let delta = toFloor - fromFloor
            return "\(delta >= 0 ? "↑" : "↓")\(abs(delta))F"
        }
        return String(
            format: "%@%.1fm",
            relativeAltitudeMeters >= 0 ? "↑" : "↓",
            abs(relativeAltitudeMeters)
        )
    }
}

private extension ConfidenceLevel {
    var displayName: String {
        switch self {
        case .low: "낮음"
        case .medium: "중간"
        case .high: "높음"
        }
    }
}

private extension TimeInterval {
    var shortDuration: String {
        let totalMinutes = max(0, Int((self / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)분" }
        if minutes == 0 { return "\(hours)시간" }
        return "\(hours)시간 \(minutes)분"
    }
}

/// 스크린 타임은 앱 이름 문자열을 늘 주지는 않는다. 토큰이 남아 있으면
/// 시스템이 그리는 실제 앱 이름·아이콘으로 채우고, 없으면 아무것도 그리지
/// 않아 기록 제목만 남긴다.
struct AppUsageNameLabel: View {
    let tokenData: Data?
    var size: CGFloat = 13
    var tint: Color = .tpInk

    init(tokenData: Data?, size: CGFloat = 13, tint: Color = .tpInk) {
        self.tokenData = tokenData
        self.size = size
        self.tint = tint
    }

    init(
        record: ActualRecord,
        tokenIndex: [UUID: Data],
        size: CGFloat = 13,
        tint: Color = .tpInk
    ) {
        self.init(tokenData: tokenIndex[record.id], size: size, tint: tint)
    }

    /// 토큰을 실제로 그릴 수 있을 때만 true. 그릴 수 없으면 호출부가
    /// 문자열 제목으로 되돌아간다.
    static func canRender(_ tokenData: Data?) -> Bool {
#if canImport(FamilyControls) && canImport(ManagedSettings)
        ApplicationTokenCache.token(for: tokenData) != nil
#else
        false
#endif
    }

    var body: some View {
#if canImport(FamilyControls) && canImport(ManagedSettings)
        if let token = ApplicationTokenCache.token(for: tokenData) {
            Label(token)
                .labelStyle(.titleAndIcon)
                .font(.taption(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
#endif
    }
}

#if canImport(FamilyControls) && canImport(ManagedSettings)
/// 시간표 막대는 드래그 중에도 다시 그려진다. 토큰을 매번 디코딩하면
/// 프레임 예산을 갉아먹으므로 한 번만 풀고 메모리에만 들고 있는다.
@MainActor
enum ApplicationTokenCache {
    private static var decoded: [Data: ApplicationToken] = [:]

    static func token(for data: Data?) -> ApplicationToken? {
        guard let data else { return nil }
        if let cached = decoded[data] { return cached }
        guard let token = try? JSONDecoder().decode(
            ApplicationToken.self,
            from: data
        ) else {
            return nil
        }
        decoded[data] = token
        return token
    }
}
#endif
