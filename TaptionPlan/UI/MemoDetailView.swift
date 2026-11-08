import PhotosUI
import SwiftUI

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
    @State private var lastDragRenderUptime: TimeInterval = 0
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
        VStack(alignment: .leading, spacing: TaptionSpacing.regular) {
            HStack(alignment: .firstTextBaseline, spacing: TaptionSpacing.snug) {
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
                            Color.tpControlFill,
                            in: RoundedRectangle(cornerRadius: TaptionRadius.control)
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
                let adjusted = adjustedMemoSpan(
                    translation: value.translation.width,
                    width: width,
                    origin: origin,
                    began: began,
                    now: now
                )
                if let lastFeedbackDate,
                   TimeSliderEngine.crossedTenMinuteTick(
                       previous: lastFeedbackDate,
                       current: adjusted.start
                   ) {
                    UISelectionFeedbackGenerator().selectionChanged()
                    self.lastFeedbackDate = adjusted.start
                }
                guard TimelineInteractionFrameGate.shouldRender(
                    lastUptime: &lastDragRenderUptime,
                    nowUptime: ProcessInfo.processInfo.systemUptime
                ) else { return }
                model.moveMemoEntry(to: clamped(adjusted.start))
            }
            .onEnded { value in
                if let origin = dragOriginSpan,
                   let began = dragStartedAt {
                    let adjusted = adjustedMemoSpan(
                        translation: value.translation.width,
                        width: width,
                        origin: origin,
                        began: began,
                        now: .now
                    )
                    model.moveMemoEntry(to: clamped(adjusted.start))
                }
                dragOriginSpan = nil
                dragStartedAt = nil
                lastFeedbackDate = nil
                lastDragRenderUptime = 0
            }
    }

    private func adjustedMemoSpan(
        translation: CGFloat,
        width: CGFloat,
        origin: TimeSpan,
        began: Date,
        now: Date
    ) -> TimeSpan {
        let elapsed = max(0.016, now.timeIntervalSince(began))
        let velocity = Double(translation) / elapsed
        let delta = Double(translation / width) * dayBounds.duration
        return TimeSliderEngine.adjust(
            origin,
            handle: .body,
            delta: delta,
            velocityPointsPerSecond: velocity,
            isLongPressPrecision: elapsed >= 0.35,
            bounds: dayBounds,
            minimumDuration: 0
        )
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
        VStack(spacing: TaptionSpacing.regular) {
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
        HStack(alignment: .top, spacing: TaptionSpacing.cozy) {
            Text(entry.occurredAt.formatted(date: .omitted, time: .shortened))
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)
                .frame(width: 38, alignment: .trailing)
                .padding(.top, 9)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: TaptionSpacing.compact) {
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
                            .taptionTouchTarget(visualWidth: 28, visualHeight: 24)
                    }
                    .accessibilityLabel("메모 메뉴")
                }
                Text(entry.text)
                    .font(.taption(size: 11))
                    .lineSpacing(3)
                if !entry.attachments.isEmpty {
                    HStack(spacing: TaptionSpacing.compact) {
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
                                        cornerRadius: TaptionRadius.small,
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
                                        .system(size: TaptionType.scaled(TaptionType.snapped(7.5)),
                                            weight: .bold
                                        )
                                    )
                                    .foregroundStyle(Color.tpSecondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 6)
                                    .background(
                                        Color.tpBackground,
                                        in: RoundedRectangle(
                                            cornerRadius: TaptionRadius.tight
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
        VStack(spacing: TaptionSpacing.regular) {
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

            HStack(spacing: TaptionSpacing.cozy) {
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
                        in: RoundedRectangle(cornerRadius: TaptionRadius.small)
                    )
                    .taptionTouchTarget(visualWidth: 42, visualHeight: 34)
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
        .background(Color.tpCard, in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(Color.tpControlStroke, lineWidth: 1)
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
            .background(dark ? Color.tpInk : Color.tpControlFill)
            .clipShape(RoundedRectangle(cornerRadius: TaptionRadius.control))
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
                    .accessibilityHidden(true)
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
