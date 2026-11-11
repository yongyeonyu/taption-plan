import SwiftUI

/// 전체 덮기 창을 열고 결과를 편집기 트랙에 반영한다(OVW1108A01).
///
/// 편집기 본문은 줄 예산이 묶여 있어 덮기 흐름은 여기 둔다. 저장은 하지 않는다 —
/// 「적용」을 눌러야 `AppModel.saveClipEditBatch`가 한 번에 저장한다.
extension MapHomeNLEClipEditor {
    /// 창을 열 때 한 번만 직접 입력 기록을 찾는다. 창이 떠 있는 동안 다시 세지 않는다.
    /// 고르는 사이 자르기·합치기로 사라진 클립은 빼고 알린다(리뷰: 말없이 일부만 바뀌던 것).
    func dropStalePicks() {
        let alive = pickedClipIDs.filter { track.clip($0) != nil }
        guard alive.count < pickedClipIDs.count else { return }
        showEditorNotice(language.text(
            "고른 클립 \(pickedClipIDs.count - alive.count)개는 편집으로 바뀌어 빠졌어요",
            "\(pickedClipIDs.count - alive.count) picked clip(s) changed while editing and were left out"
        ))
        pickedClipIDs = alive
    }

    func presentOverwrite() {
        dropStalePicks()
        overwriteUserOwnedIDs = Self.userOwnedSourceIDs(
            in: track,
            actuals: model.snapshot.actuals,
            corrections: model.snapshot.settings.activityCorrections
        )
        isOverwritePresented = true
    }

    /// 트랙 클립이 딛고 선 기록 중 사용자가 직접 만들거나 고친 것.
    static func userOwnedSourceIDs(
        in track: NLETrack,
        actuals: [ActualRecord],
        corrections: [UUID: ActivityCorrection]
    ) -> Set<UUID> {
        let sourceIDs = Set(track.clips.flatMap(\.parent.sourceIDs))
        guard !sourceIDs.isEmpty else { return [] }
        return Set(actuals.lazy
            .filter { sourceIDs.contains($0.id) && ActualRecord.userOwned($0, activityCorrections: corrections) }
            .map(\.id))
    }

    var overwriteSheet: some View {
        MapHomeNLEOverwriteSheet(
            language: language,
            track: track,
            subTrack: subTrack,
            userOwnedSourceIDs: overwriteUserOwnedIDs,
            selectedCategoryID: selectedClip?.option.categoryID,
            pickedClipIDs: pickedClipIDs,
            categories: categoryOptions
        ) { applyOverwrite($0) }
    }

    /// 분류 메뉴 아래: 전체 덮기와 여러 개 골라 덮기(대표 지시 2026-11-11: 한 번에 여러 클립 덮어쓰기).
    /// 고르는 중에는 클립을 누를 때마다 넣고 빼며, 분류를 고르면 고른 클립 모두에 한 번에 적용한다.
    @ViewBuilder
    var overwriteMenuButtons: some View {
        Divider()
        if pickedClipIDs.isEmpty {
            Button { startPicking() } label: {
                Label(language.text("여러 개 골라 덮기", "Pick clips to overwrite"), systemImage: "checklist")
            }
        } else {
            Button(role: .cancel) { pickedClipIDs = [] } label: {
                Label(language.text("고르기 끝내기 (\(pickedClipIDs.count)개)", "Stop picking (\(pickedClipIDs.count))"), systemImage: "xmark.circle")
            }
        }
        Button { presentOverwrite() } label: {
            Label(language.text("전체 덮기", "Overwrite all"), systemImage: "rectangle.on.rectangle")
        }
    }

    func startPicking() {
        pickedClipIDs = Set([selectedClipID].compactMap { $0 })
        if pickedClipIDs.isEmpty, let clip = track.clip(atMinute: playheadMinute) { pickedClipIDs = [clip.id] }
        showEditorNotice(language.text(
            "덮을 클립을 누르거나 위아래로 끌어 한 번에 고르세요. 「분류」에서 고르면 모두 바뀌고 한 덩어리로 합쳐집니다.",
            "Tap clips or drag up and down to pick many at once. Choose a category to change and merge them."
        ))
    }

    /// 고르는 중에 대분류 줄을 끌면 손가락이 지나간 클립을 모두 고른다(RNG1111A01).
    func pickRange(from anchor: Int, to minute: Int, adding base: Set<String>) {
        let next = base.union(track.clipIDs(from: anchor, to: minute))
        guard next != pickedClipIDs else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        pickedClipIDs = next
    }

    func togglePicked(_ id: String) {
        UISelectionFeedbackGenerator().selectionChanged()
        if pickedClipIDs.contains(id) { pickedClipIDs.remove(id) } else { pickedClipIDs.insert(id) }
    }

    /// 고른 클립이 있으면 그 클립 모두를 이 분류로 덮고 true. 고르기는 끝낸다.
    func applyToPicked(_ category: MapHomeSidebarMajorCategory) -> Bool {
        guard !pickedClipIDs.isEmpty else { return false }
        dropStalePicks()
        applyOverwrite(NLEOverwriteRequest(category: category, scope: .picked, mergesAfter: true))
        pickedClipIDs = []
        return true
    }

    /// 전체 덮기·합치기를 적용한다. 실제로 바뀐 것이 없으면 되돌리기를 쌓지 않는다.
    /// 대분류·상세활동을 한 칸에 담으므로 편집기 되돌리기 한 번에 함께 돌아온다.
    func applyOverwrite(_ request: NLEOverwriteRequest) {
        let result = NLEOverwritePolicy.apply(
            track,
            subTrack: subTrack,
            option: request.category.map { Self.option(for: $0, language: language) },
            scope: request.scope,
            selectedCategoryID: selectedClip?.option.categoryID,
            mergesAfter: request.mergesAfter,
            userOwnedSourceIDs: overwriteUserOwnedIDs,
            includesUserOwned: request.includesUserOwned,
            clearsDetails: request.clearsDetails,
            pickedClipIDs: pickedClipIDs
        )
        if result.skipped > 0 {
            showEditorNotice(language.text(
                "직접 입력한 클립 \(result.skipped)개는 그대로 두었습니다",
                "Left \(result.skipped) clip(s) you entered unchanged"
            ))
        }
        guard result.changed + result.merged + result.removedDetails > 0 else { return }
        pushUndo()
        track = result.track
        if let detail = result.subTrack { subTrack = detail }
        // 합쳐져 사라진 클립을 가리키지 않게 재생 헤드 자리의 클립으로 옮긴다.
        selectedClipID = track.clip(atMinute: playheadMinute)?.id
        selectedSubClipID = nil
        pickedClipIDs = []
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func showSaveFailedNotice() {
        showEditorNotice(language.text(
            "저장하지 못했습니다. 기록은 하나도 바뀌지 않았습니다. 다시 적용해 보세요.",
            "Couldn't save. No records changed. Try applying again."
        ))
    }

    func showEditorNotice(_ text: String) {
        editorNotice = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if editorNotice == text { editorNotice = nil }
        }
    }

    @ViewBuilder
    var editorNoticeBanner: some View {
        if let editorNotice {
            Text(editorNotice)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                .foregroundStyle(Color.tpInk)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.tpSurface, in: Capsule())
                .overlay { Capsule().stroke(Color.tpLine, lineWidth: 1) }
                .padding(.top, 8)
                .padding(.horizontal, 16)
                .onTapGesture { self.editorNotice = nil }
                .transition(.opacity)
                .accessibilityIdentifier("nleEditorNotice")
        }
    }
}

/// 경계 손잡이를 이웃의 먼 쪽 끝까지 가져갔을 때 묻는 합치기 확인.
struct NLEMergePrompt: Equatable {
    let clipID: String
    let neighborID: String
    let clipTitle: String
    let neighborTitle: String
}

