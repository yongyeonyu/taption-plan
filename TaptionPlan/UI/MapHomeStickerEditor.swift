import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

enum MapHomeStickerEditorTarget: Identifiable {
    case sticker(UUID)
    case memo(UUID)
    case newMemo(UUID)

    var id: String {
        switch self {
        case .sticker(let id): "sticker-\(id.uuidString)"
        case .memo(let id): "memo-\(id.uuidString)"
        case .newMemo(let id): "new-memo-\(id.uuidString)"
        }
    }
}

struct MapHomeMapStickerMarker: View {
    let sticker: MapSticker

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: sticker.systemImage)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
            Text(sticker.title)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(Color.tpInk)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Color(hex: sticker.colorHex).opacity(0.92),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .fixedSize()
        .frame(
            minWidth: TaptionMenuMetrics.minimumHitSize,
            minHeight: TaptionMenuMetrics.minimumHitSize
        )
    }
}

struct MapHomeMapMemoMarker: View {
    let memo: ActionMemo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "note.text")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
                Text(memo.occurredAt.formatted(date: .omitted, time: .shortened))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .bold))
            }
            Text(memo.text)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 118, alignment: .leading)
        }
        .foregroundStyle(Color.tpInk)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Color.tpPastelButter.opacity(0.94),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.tpReferenceGold.opacity(0.72), lineWidth: 1)
        }
        // 말풍선 꼬리: 아래 가운데 끝이 선택한 위치(핀 끝)에 닿는다.
        .padding(.bottom, 7)
        .overlay(alignment: .bottom) {
            MapHomeBubbleTail()
                .fill(Color.tpPastelButter.opacity(0.94))
                .overlay {
                    MapHomeBubbleTail()
                        .stroke(Color.tpReferenceGold.opacity(0.72), lineWidth: 1)
                }
                .frame(width: 14, height: 8)
        }
        .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
        .fixedSize()
        .frame(
            minWidth: TaptionMenuMetrics.minimumHitSize,
            minHeight: TaptionMenuMetrics.minimumHitSize
        )
    }
}

/// 말풍선 꼬리(아래를 가리키는 삼각형).
struct MapHomeBubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct MapHomeStickerEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var model: AppModel
    let target: MapHomeStickerEditorTarget
    let language: MapHomeLanguage
    /// "위치 추가"를 누르면 편집 화면을 닫고 지도에서 핀을 고르게 한다. 메모 id를 넘긴다.
    var onRequestLocation: ((UUID) -> Void)? = nil

    @State private var title = ""
    @State private var memoText = ""
    @State private var hasTime = false
    @State private var showsAsSticker = false
    @State private var showsMapStickerNeedsLocation = false
    @State private var keepsDraft = false
    @State private var memoKind: MemoKind = .idea
    @State private var placement: MapStickerPlacement = .map
    @State private var systemImage = "star.fill"
    @State private var colorHex = "#F28FA9"
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var occurredAt = Date()
    @State private var isDeleteConfirmationPresented = false
    @State private var didSave = false
    @State private var dictation = MapHomeDictation()
    @State private var dictationBase = ""
    /// 권한·마이크를 준비하는 동안에도 키보드를 막는다.
    @State private var isDictationStarting = false
    @State private var memoFocusToken = 0
    @State private var polish = MemoPolishController()

    private let symbols = [
        "star.fill", "heart.fill", "flag.fill", "pin.fill",
        "sparkles", "leaf.fill"
    ]
    private let colors = [
        "#F28FA9", "#A9CFF0", "#8FD9C5", "#F2D58D",
        "#C2B4E9", "#F2B18D"
    ]

    private var isSticker: Bool {
        if case .sticker = target { return true }
        return false
    }

    private var isNewMemo: Bool {
        if case .newMemo = target { return true }
        return false
    }

    private var canSave: Bool {
        let cleanTitle = (isSticker ? title : memoText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return false }
        // 메모는 내용만 있으면 저장된다(위치는 선택). 스티커는 위치가 필요하다.
        if !isSticker { return true }
        if placement == .schedule { return true }
        return editedPoint != nil
    }

    private var editedPoint: GeoPoint? {
        guard let latitude = Double(latitudeText),
              let longitude = Double(longitudeText),
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else {
            return nil
        }
        return GeoPoint(
            latitude: latitude,
            longitude: longitude,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    memoFields

                    editorCard {
                        Button(language.text("삭제", "Delete"), role: .destructive) {
                            isDeleteConfirmationPresented = true
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .background(Color.tpBackground)
            .safeAreaInset(edge: .bottom) { dictationBar }
            .tint(Color.tpAccent)
            .alert(
                language.text("위치를 먼저 고르세요", "Choose a location first"),
                isPresented: $showsMapStickerNeedsLocation
            ) {
                Button(language.text("위치 고르기", "Choose location")) { requestLocation() }
                Button(language.text("취소", "Cancel"), role: .cancel) {}
            } message: {
                Text(language.text("지도 스티커는 위치가 있어야 지도에 보여요. 위치를 고르거나 추가 위치를 일정으로 바꾸세요.", "A map sticker needs a location to show on the map. Pick a location or change the placement to schedule."))
            }
            .navigationTitle(
                language.text(
                    isSticker
                        ? "메모 스티커 수정"
                        : (isNewMemo ? "메모 추가" : "메모 수정"),
                    isSticker
                        ? "Edit memo sticker"
                        : (isNewMemo ? "Add memo" : "Edit memo")
                )
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("취소", "Cancel")) { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("저장", "Save")) { save() }
                        .disabled(!canSave)
                }
            }
            .confirmationDialog(
                language.text("이 항목을 삭제할까요?", "Delete this item?"),
                isPresented: $isDeleteConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button(language.text("삭제", "Delete"), role: .destructive) {
                    delete()
                }
                Button(language.text("취소", "Cancel"), role: .cancel) {}
            }
            .onAppear {
                load()
                polish.refreshAvailability()
            }
            // 설정에서 Apple Intelligence를 켜고 돌아오면 바로 반영한다.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { polish.refreshAvailability() }
            }
            .onChange(of: memoText) { polish.clearNotice() }
            .onDisappear {
                polish.cancel()
                if isNewMemo, !didSave, !keepsDraft {
                    deleteNewMemoIfNeeded()
                }
            }
        }
    }

    /// 음성 입력 버튼은 편집 화면 하단 가운데에 고정한다. 누르면 권한을 바로 요청하고, 말한 내용이 메모 글자로 이어진다.
    private var dictationBar: some View {
        VStack(spacing: 6) {
            if let message = dictation.errorMessage {
                Text(message)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                    .foregroundStyle(Color.tpHoliday)
                    .multilineTextAlignment(.center)
                if MapHomeDictation.isPermissionDenied {
                    Button(language.text("설정 열기", "Open Settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
                }
            }
            if dictation.isListening {
                HStack(alignment: .center, spacing: 3) {
                    ForEach(0..<16, id: \.self) { index in
                        Capsule()
                            .fill(Color.tpHoliday)
                            .frame(width: 3, height: 4 + 26 * dictation.level * (0.45 + 0.55 * abs(sin(Double(index) * 1.7))))
                    }
                }
                .frame(height: 30)
                .animation(.easeOut(duration: 0.1), value: dictation.level)
            }
            Button {
                toggleDictation()
            } label: {
                Image(systemName: dictation.isListening ? "mic.fill" : "mic")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(26)), weight: .semibold))
                    .foregroundStyle(dictation.isListening ? Color.tpHoliday : Color.tpAccent)
                    .frame(width: 68, height: 68)
                    .background(Color.tpAccent.opacity(0.14), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(polish.isPolishing)
            .accessibilityLabel(language.text(dictation.isListening ? "녹음 끝내기" : "음성 첨부", dictation.isListening ? "Finish recording" : "Voice attachment"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var isDictationBusy: Bool {
        isDictationStarting || dictation.isListening || dictation.isTranscribing
    }

    /// 다듬기 줄. 미지원 기기·OS에서는 아무것도 보이지 않는다.
    @ViewBuilder
    private var memoPolishRow: some View {
        if polish.availability.showsButton || polish.history.canSwap {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 12) {
                    if polish.history.canSwap {
                        Button(polish.history.isShowingOriginal
                            ? language.text("다듬은 글로", "Use polished")
                            : language.text("되돌리기", "Undo")) {
                            if let text = polish.swap(current: memoText) { memoText = text }
                        }
                        .disabled(polish.isPolishing || isDictationBusy)
                        .accessibilityIdentifier("memo-polish-undo")
                    }
                    Spacer(minLength: 0)
                    if polish.availability.showsButton {
                        memoPolishButton
                    }
                }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold))
                if let message = memoPolishMessage {
                    Text(message.text)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                        .foregroundStyle(message.isFailure ? Color.tpHoliday : Color.tpSecondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("memo-polish-message")
                }
            }
        }
    }

    private var memoPolishButton: some View {
        Button {
            polish.polish(currentText: { memoText }, apply: { memoText = $0 })
        } label: {
            HStack(spacing: 5) {
                if polish.isPolishing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                }
                Text(polish.isPolishing
                    ? language.text("다듬는 중…", "Polishing…")
                    : language.text("AI 다듬기", "AI polish"))
            }
            .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(polish.canPolish(memoText) && !isDictationBusy ? Color.tpAccent : Color.tpSecondary)
        .disabled(!polish.canPolish(memoText) || isDictationBusy)
        .accessibilityLabel(language.text("AI로 문장 다듬기", "Polish text with AI"))
        .accessibilityIdentifier("memo-polish-button")
    }

    /// 쓸 수 없는 이유가 먼저고, 그다음 마지막 다듬기 결과 안내를 보여 준다.
    private var memoPolishMessage: (text: String, isFailure: Bool)? {
        switch polish.availability {
        case .appleIntelligenceOff:
            return (language.text("설정에서 Apple Intelligence를 켜면 쓸 수 있어요.", "Turn on Apple Intelligence in Settings to use this."), false)
        case .modelNotReady:
            return (language.text("Apple Intelligence 모델을 준비하는 중이에요.", "The Apple Intelligence model is getting ready."), false)
        case .available, .unsupported:
            break
        }
        guard let notice = polish.notice else { return nil }
        let text = switch notice {
        case .unchanged: language.text("고칠 곳을 찾지 못했어요.", "Nothing to fix.")
        case .textChanged: language.text("글이 바뀌어 다듬기를 멈췄어요.", "The text changed, so polishing stopped.")
        case .tooLong: language.text("글이 길어 다듬지 못했어요. 1,500자 이하로 줄여 주세요.", "This is too long to polish. Keep it under 1,500 characters.")
        case .rejected: language.text("결과가 원문과 달라 적용하지 않았어요.", "The result differed from your text, so it wasn't applied.")
        case .blockedContent: language.text("이 내용은 Apple Intelligence가 다듬지 못해요.", "Apple Intelligence can't polish this content.")
        case .unsupportedLanguage: language.text("이 언어는 다듬지 못해요.", "This language isn't supported.")
        case .failed: language.text("다듬지 못했어요. 잠시 뒤 다시 해 주세요.", "Couldn't polish this. Try again later.")
        }
        return (text, notice.isFailure)
    }

    /// 스티커를 메모로 되돌린다. 시간은 스티커 시간을 그대로 쓴다.
    private func revertStickerToMemo() {
        guard case .sticker(let id) = target,
              let sticker = model.snapshot.stickers.first(where: { $0.id == id }) else { return }
        // 제목과 메모 본문을 합쳐 글자를 잃지 않는다.
        let body = [sticker.title, sticker.memo ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard let memoID = model.addMemoDraft(text: body, occurredAt: sticker.occurredAt, mapPoint: nil, isTimeless: false) else { return }
        guard model.updateMapMemo(memoID, text: body, kind: .idea, mapPoint: nil, occurredAt: sticker.occurredAt, isTimeless: false) else {
            model.discardMapMemoDraft(memoID)
            return
        }
        model.deleteMapSticker(id)
        didSave = true
        dismiss()
    }

    /// 메모 입력칸과 마이크 버튼. 마이크를 누르면 말한 내용이 메모 끝에 글자로 이어진다.
    private func memoInputField(prompt: Text?) -> some View {
        ZStack(alignment: .topLeading) {
            if memoText.isEmpty {
                (prompt ?? Text(language.text("메모 내용", "Memo text")))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(17))))
                    .foregroundStyle(Color.tpSecondary)
                    .allowsHitTesting(false)
            }
            MapHomeMemoTextView(
                text: $memoText,
                suppressesKeyboard: isDictationStarting || dictation.isListening || dictation.isTranscribing,
                focusToken: memoFocusToken
            )
            .frame(minHeight: 120)
        }
        .onDisappear { dictation.stop() }
    }

    private func toggleDictation() {
        if dictation.isListening {
            dictation.stop()
        } else {
            // 준비 중이거나 마지막 글자를 기다릴 때 기준 글자를 다시 잡으면 같은 말이 두 번 붙는다.
            guard !isDictationStarting, !dictation.isTranscribing, !polish.isPolishing else { return }
            dictationBase = MapHomeDictationTranscript.base(from: memoText)
            // 키보드를 먼저 막고 입력칸에 커서를 둔다. 글자 변환이 끝나면 그 글자를 메모에 붙인다.
            isDictationStarting = true
            memoFocusToken += 1
            dictation.onPartial = { text in
                memoText = dictationBase + text
            }
            dictation.onTranscribed = { text in
                memoText = dictationBase + text
            }
            let identifier = language == .korean ? "ko-KR" : "en-US"
            // 녹음 파일은 이 메모의 오디오 첨부로 남긴다.
            let memoID: UUID? = {
                switch target {
                case .memo(let id), .newMemo(let id): id
                case .sticker: nil
                }
            }()
            dictation.onRecorded = { url in
                if let memoID { model.attachAudio(toMemo: memoID, localIdentifier: url.path) }
            }
            Task {
                await dictation.start(localeIdentifier: identifier)
                isDictationStarting = false
            }
        }
    }

    /// 달력 화면과 같은 카드 스타일(흰 표면, 둥근 모서리, 14pt 여백).
    @ViewBuilder
    private func editorCard<Content: View>(title: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 5) {
                    TaptionCuteIcon("figure.walk", size: 15)
                        .foregroundStyle(Color.tpAccent)
                    Text(title)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.tpLine, lineWidth: 1)
        }
    }

    /// 메모 추가와 스티커 수정이 같은 화면을 쓴다. 스티커는 제목과 종류·색·위치를 더 고른다.
    @ViewBuilder
    private var memoFields: some View {
        editorCard(title: isSticker ? language.text("메모 스티커", "Memo sticker") : language.text("메모", "Memo")) {
            if isSticker {
                TextField(language.text("제목", "Title"), text: $title)
            }
            memoInputField(prompt: Text(language.text("새 메모", "New memo")))
            memoPolishRow
        }
        if isSticker {
            editorCard {
                stickerOptions
            }
        } else {
            editorCard {
                Toggle(language.text("스티커로 표시", "Show as sticker"), isOn: $showsAsSticker)
                if showsAsSticker {
                    stickerOptions
                }
            }
        }
        editorCard(title: language.text("시간", "Time")) {
            if !isSticker {
                Toggle(language.text("시간 지정", "Set a time"), isOn: $hasTime)
            }
            if hasTime || isSticker {
                DatePicker(
                    language.text("시간", "Time"),
                    selection: $occurredAt,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
        }
        editorCard(title: language.text("위치", "Location")) {
            if let point = editedPoint {
                // 위치를 지도에 보여 준다.
                Map(
                    initialPosition: .region(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                        latitudinalMeters: 400,
                        longitudinalMeters: 400
                    )),
                    interactionModes: []
                ) {
                    Marker("", coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
                        .tint(Color.tpAccent)
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(String(format: "%.5f, %.5f", point.latitude, point.longitude))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                Button(language.text("위치 다시 고르기", "Choose again")) { requestLocation() }
                Button(language.text("위치 지우기", "Remove location"), role: .destructive) {
                    latitudeText = ""
                    longitudeText = ""
                }
            } else {
                Button {
                    requestLocation()
                } label: {
                    Label(language.text("위치 추가", "Add location"), systemImage: "mappin.and.ellipse")
                }
            }
        }
        if isSticker {
            editorCard {
                Button(language.text("메모로 되돌리기", "Turn back into a memo")) {
                    revertStickerToMemo()
                }
                Text(language.text("스티커 내용을 메모로 다시 만들고 스티커는 지워요.", "Creates a memo with this text and removes the sticker."))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            }
        }
    }

    /// 스티커 종류·색·추가 위치. 메모를 스티커로 표시할 때와 스티커 수정에서 같이 쓴다.
    @ViewBuilder
    private var stickerOptions: some View {
        Picker(
            language.text("추가 위치", "Placement"),
            selection: $placement
        ) {
            Text(language.text("지도", "Map")).tag(MapStickerPlacement.map)
            Text(language.text("일정", "Schedule")).tag(MapStickerPlacement.schedule)
        }
        symbolPicker
        colorPicker
    }

    /// 위치 고르기: 지금까지 쓴 내용을 임시로 남기고 편집 화면을 닫는다. 핀을 고르면 다시 열린다.
    private func requestLocation() {
        switch target {
        case .newMemo(let id):
            keepsDraft = true
            model.updateMemoDraft(
                id,
                text: memoText,
                occurredAt: occurredAt,
                isTimeless: !hasTime,
                mapPoint: .some(editedPoint)
            )
            dismiss()
            onRequestLocation?(id)
        case .memo(let id):
            keepsDraft = true
            if !memoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = model.updateMapMemo(
                    id,
                    text: memoText,
                    kind: memoKind,
                    mapPoint: editedPoint,
                    occurredAt: occurredAt,
                    isTimeless: !hasTime
                )
            }
            dismiss()
            onRequestLocation?(id)
        case .sticker:
            break
        }
    }

    private var symbolPicker: some View {
        HStack(spacing: 9) {
            ForEach(symbols, id: \.self) { symbol in
                Button {
                    systemImage = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
                        .foregroundStyle(Color(hex: colorHex))
                        .frame(width: 34, height: 34)
                        .background(
                            systemImage == symbol
                                ? Color(hex: colorHex).opacity(0.18)
                                : Color.black.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .taptionHitOutset(horizontal: 5, vertical: 5)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(systemImage == symbol ? .isSelected : [])
            }
        }
    }

    private var colorPicker: some View {
        HStack(spacing: 10) {
            ForEach(colors, id: \.self) { color in
                Button {
                    colorHex = color
                } label: {
                    Circle()
                        .fill(Color(hex: color))
                        .frame(width: 24, height: 24)
                        .overlay {
                            Circle()
                                .stroke(
                                    colorHex == color ? Color.tpInk : .white,
                                    lineWidth: colorHex == color ? 2 : 1
                                )
                        }
                        .taptionHitOutset(horizontal: 10, vertical: 10)
                }
                .buttonStyle(.plain)
                // 색만 그린 단추는 읽어 줄 이름이 없다. 순서로 이름을 붙이고 고른 것을 알린다.
                .accessibilityLabel(
                    language.text(
                        "색 \((colors.firstIndex(of: color) ?? 0) + 1)",
                        "Color \((colors.firstIndex(of: color) ?? 0) + 1)"
                    )
                )
                .accessibilityAddTraits(colorHex == color ? .isSelected : [])
            }
        }
    }

    private func load() {
        switch target {
        case .sticker(let id):
            guard let sticker = model.snapshot.stickers.first(where: { $0.id == id }) else { return }
            title = sticker.title
            memoText = sticker.memo ?? ""
            placement = sticker.placement
            systemImage = sticker.systemImage
            colorHex = sticker.colorHex
            occurredAt = sticker.occurredAt
            hasTime = true
            if let point = sticker.point {
                latitudeText = String(format: "%.6f", point.latitude)
                longitudeText = String(format: "%.6f", point.longitude)
            }
        case .memo(let id), .newMemo(let id):
            guard let memo = model.snapshot.memos.first(where: { $0.id == id }) else { return }
            // 임시로 넣어 둔 문구는 빈칸으로 두고, 위치를 고르고 돌아온 초안은 쓴 글을 그대로 보여 준다.
            let placeholders = ["새 메모", "New memo", "새 지도 메모", "New map memo"]
            memoText = (isNewMemo && placeholders.contains(memo.text)) ? "" : memo.text
            memoKind = memo.kind
            occurredAt = memo.occurredAt
            hasTime = memo.isTimeless != true
            // 저장된 스티커 정보가 있으면 스티커 토글과 종류·색을 그대로 보여 준다.
            showsAsSticker = memo.isSticker
            if let symbol = memo.stickerSymbol { systemImage = symbol }
            if let color = memo.stickerColorHex { colorHex = color }
            placement = .schedule
            if let point = memo.mapPoint {
                latitudeText = String(format: "%.6f", point.latitude)
                longitudeText = String(format: "%.6f", point.longitude)
            }
        }
    }

    private func save() {
        switch target {
        case .sticker(let id):
            let point = placement == .map ? editedPoint : nil
            guard model.updateMapSticker(
                id,
                title: title,
                memo: memoText,
                systemImage: systemImage,
                colorHex: colorHex,
                placement: placement,
                point: point,
                planID: model.snapshot.stickers.first(where: { $0.id == id })?.planID,
                occurredAt: occurredAt
            ) else { return }
        case .memo(let id), .newMemo(let id):
            // 메모 하나가 스티커 정보를 함께 가진다. 스티커를 끄면 일반 메모가 된다.
            if showsAsSticker, placement == .map, editedPoint == nil {
                showsMapStickerNeedsLocation = true
                return
            }
            let pinsToMap = showsAsSticker && placement == .schedule ? nil : editedPoint
            guard model.updateMapMemo(
                id,
                text: memoText,
                kind: memoKind,
                mapPoint: pinsToMap,
                occurredAt: occurredAt,
                isTimeless: !hasTime
            ) else { return }
            model.setMemoSticker(
                id,
                symbol: showsAsSticker ? systemImage : nil,
                colorHex: showsAsSticker ? colorHex : nil
            )
            didSave = true
        }
        dismiss()
    }

    private func cancel() {
        didSave = true
        deleteNewMemoIfNeeded()
        dismiss()
    }

    private func deleteNewMemoIfNeeded() {
        guard case .newMemo(let id) = target else { return }
        model.discardMapMemoDraft(id)
    }

    private func delete() {
        didSave = true
        switch target {
        case .sticker(let id): model.deleteMapSticker(id)
        case .memo(let id): model.deleteMemo(id)
        case .newMemo(let id): model.discardMapMemoDraft(id)
        }
        dismiss()
    }

}
