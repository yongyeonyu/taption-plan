import SwiftUI

/// 전체 덮기의 적용 범위.
///
/// "전체"를 화면에 보이는 구간으로 잡지 않는다. 이 편집기는 하루를 세로로 세운
/// 타임라인이라 같은 손짓이 배율에 따라 다른 시간을 덮게 되기 때문이다.
enum NLEOverwriteScope: String, CaseIterable, Identifiable {
    /// 원본 기록이 있는 하루 전체.
    case wholeDay
    /// 지금 고른 클립과 같은 분류의 클립만.
    case sameCategory
    /// 「여러 개 골라 덮기」로 고른 클립만.
    case picked

    var id: String { rawValue }

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .wholeDay: language.text("하루 전체", "Whole day")
        case .sameCategory: language.text("같은 분류만", "Same category")
        case .picked: language.text("고른 클립만", "Picked clips")
        }
    }

    func explanation(_ language: MapHomeLanguage) -> String {
        switch self {
        case .wholeDay:
            language.text(
                "기록이 있는 클립과 미확인 클립을 모두 바꿉니다.",
                "Every recorded clip and every unconfirmed clip changes."
            )
        case .sameCategory:
            language.text(
                "지금 고른 클립과 같은 분류인 클립만 바꿉니다.",
                "Only clips in the same category as the selected clip change."
            )
        case .picked:
            language.text(
                "「여러 개 골라 덮기」로 고른 클립만 바꿉니다.",
                "Only the clips you picked change."
            )
        }
    }
}

/// 여러 개로 나뉜 클립을 한 번에 같은 분류로 덮는 창.
///
/// BOKKI STUDIO의 자막 합치기와 같은 자리다. 자막이 여러 조각으로 나뉘어 있을 때
/// 한 번에 합쳐 하나로 만드는 것처럼, 센서가 잘게 나눈 클립을 하나의 분류로 덮고
/// 손으로 가른 흔적은 합쳐 되돌린다. 누르기 전에 몇 개가 바뀌는지 보여 준다.
struct MapHomeNLEOverwriteSheet: View {
    let language: MapHomeLanguage
    let track: NLETrack
    /// 상세활동 줄. 「상세활동도 지움」이 지울 수를 센다.
    var subTrack: NLETrack? = nil
    /// 직접 입력한(사용자 소유) 기록 ID. 덮기 전에 한 번 더 묻는다.
    var userOwnedSourceIDs: Set<UUID> = []
    /// 지금 고른 클립의 분류. '같은 분류만'의 기준이다.
    let selectedCategoryID: String?
    /// 「여러 개 고르기」로 고른 클립. 있으면 범위를 「고른 클립만」으로 연다.
    var pickedClipIDs: Set<String> = []
    let categories: [MapHomeSidebarMajorCategory]
    var onApply: (NLEOverwriteRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scope: NLEOverwriteScope = .wholeDay
    @State private var mergesAfter = true
    @State private var pickedCategoryID: String?
    @State private var clearsDetails = false
    @State private var isConfirmingUserOwned = false

    private var pickedCategory: MapHomeSidebarMajorCategory? {
        categories.first { $0.id == pickedCategoryID }
    }

    private var pickedOption: ActivityCorrectionOption? {
        pickedCategory.map { MapHomeNLEClipEditor.option(for: $0, language: language) }
    }

    /// 고른 분류로 덮으면 실제로 바뀌는 클립.
    private var targets: [NLEClip] {
        guard let pickedOption else { return [] }
        return NLEOverwritePolicy.targets(
            track, option: pickedOption, scope: scope, selectedCategoryID: selectedCategoryID, pickedClipIDs: pickedClipIDs
        )
    }

    private var userOwnedCount: Int {
        let parents = NLEOverwritePolicy.userOwnedParents(targets, userOwnedSourceIDs: userOwnedSourceIDs)
        return targets.filter { parents.contains($0.parent) }.count
    }

    private var affectedCount: Int {
        NLEOverwritePolicy.affectedCount(
            track,
            scope: scope,
            selectedCategoryID: selectedCategoryID,
            pickedClipIDs: pickedClipIDs
        )
    }

    private var mergeableCount: Int {
        NLEOverwritePolicy.mergeableCount(track)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    scopeSection
                    categorySection
                    detailSection
                    mergeSection
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 14)
            }
            footer
        }
        .background(Color.tpBackground)
        .presentationDetents([.medium, .large])
        .onAppear { if !pickedClipIDs.isEmpty { scope = .picked } }
        .presentationDragIndicator(.visible)
        .confirmationDialog(
            language.text("직접 입력한 기록이 있습니다", "Includes records you entered"),
            isPresented: $isConfirmingUserOwned,
            titleVisibility: .visible
        ) {
            Button(language.text("함께 덮기", "Overwrite them too"), role: .destructive) { submit(includesUserOwned: true) }
            Button(language.text("직접 입력 \(userOwnedCount)개 건너뛰기", "Skip \(userOwnedCount) entered clip(s)")) {
                submit(includesUserOwned: false)
            }
            Button(language.text("취소", "Cancel"), role: .cancel) {}
        } message: {
            Text(language.text(
                "덮을 클립 중 \(userOwnedCount)개는 직접 입력한 기록입니다. 건너뛰면 그대로 남습니다.",
                "\(userOwnedCount) of the clips hold records you entered. Skipped clips stay as they are."
            ))
        }
    }

    private func submit(includesUserOwned: Bool) {
        guard let pickedCategory else { return }
        onApply(NLEOverwriteRequest(
            category: pickedCategory,
            scope: scope,
            mergesAfter: mergesAfter,
            clearsDetails: clearsDetails,
            includesUserOwned: includesUserOwned
        ))
        dismiss()
    }

    private var detailCount: Int {
        guard let subTrack, let pickedOption else { return 0 }
        return NLEOverwritePolicy.detailCount(subTrack, inside: targets, fill: pickedOption)
    }

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $clearsDetails) {
                Text(language.text("상세활동도 지움", "Clear detail activities too"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                    .foregroundStyle(Color.tpInk)
            }
            .tint(Color.tpAccent)
            .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
            Text(clearsDetails
                ? language.text(
                    "범위 안 상세활동 \(detailCount)개를 지우고 새 분류로 채웁니다.",
                    "Clears \(detailCount) detail activit(ies) in range and fills them with the new category."
                )
                : language.text("끄면 상세활동은 그대로 남습니다.", "When off, detail activities stay."))
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
            .foregroundStyle(Color.tpSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(language.text("전체 덮기", "Overwrite all"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(19)), weight: .bold))
                Text(language.text(
                    "나뉜 클립을 한 번에 같은 분류로 바꿉니다",
                    "Change every split clip to one category at once"
                ))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(width: TaptionMenuMetrics.minimumHitSize, height: TaptionMenuMetrics.minimumHitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("닫기", "Close"))
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(language.text("적용 범위", "Scope"))
            Picker("", selection: $scope) {
                ForEach(NLEOverwriteScope.allCases.filter { $0 != .picked || !pickedClipIDs.isEmpty }) { option in
                    Text("\(option.title(language)) \(count(for: option))").tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(Color.tpAccent)
            Text(scope.explanation(language))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                .foregroundStyle(Color.tpSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func count(for scope: NLEOverwriteScope) -> Int {
        NLEOverwritePolicy.affectedCount(
            track,
            scope: scope,
            selectedCategoryID: selectedCategoryID,
            pickedClipIDs: pickedClipIDs
        )
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(language.text("덮을 분류", "Category"))
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                ],
                spacing: 8
            ) {
                ForEach(categories) { category in
                    categoryChip(category)
                }
            }
        }
    }

    private func categoryChip(_ category: MapHomeSidebarMajorCategory) -> some View {
        let isPicked = category.id == pickedCategoryID
        return Button {
            pickedCategoryID = category.id
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: category.systemImage)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                    .foregroundStyle(category.tint)
                    .frame(width: 16)
                Text(category.localizedTitle(language))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if isPicked {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold))
                        .foregroundStyle(Color.tpAccent)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: TaptionMenuMetrics.minimumHitSize)
            .background(
                isPicked ? Color.tpAccent.opacity(0.12) : Color.tpSurface,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isPicked ? Color.tpAccent : Color.tpLine, lineWidth: isPicked ? 1.6 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.localizedTitle(language))
        .accessibilityAddTraits(isPicked ? AccessibilityTraits.isSelected : [])
    }

    private var mergeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $mergesAfter) {
                Text(language.text("같은 분류끼리 합치기", "Merge same categories"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                    .foregroundStyle(Color.tpInk)
            }
            .tint(Color.tpAccent)
            .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
            Text(language.text(
                "손으로 가른 클립을 하나로 되돌립니다. 지금 합칠 수 있는 곳 \(mergeableCount)군데.",
                "Joins the clips you split by hand. \(mergeableCount) place(s) can merge now."
            ) + " " + language.text(
                "같은 원본 구간끼리만 합쳐집니다.",
                "Only clips from the same source segment merge."
            ))
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
            .foregroundStyle(Color.tpSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Text(summaryLine)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                .foregroundStyle(pickedCategory == nil ? Color.tpSecondary : Color.tpAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let pickedOption, let sleepLine = NLEOverwritePolicy.sleepChangeText(
                minutes: NLEOverwritePolicy.sleepMinutesChanged(targets, to: pickedOption),
                language: language
            ) {
                Label(sleepLine, systemImage: "bed.double.fill")
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("nleOverwriteSleepChange")
            }
            HStack(spacing: 10) {
                if mergeableCount > 0 {
                    Button {
                        onApply(NLEOverwriteRequest(category: nil, scope: scope, mergesAfter: true))
                        dismiss()
                    } label: {
                        Text(language.text("합치기만", "Merge only"))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                            .foregroundStyle(Color.tpAccent)
                            .padding(.horizontal, 14)
                            .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
                            .background(Color.tpAccent.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(language.text(
                        "분류는 그대로 두고 손으로 가른 클립만 합칩니다",
                        "Merges hand-split clips without changing categories"
                    ))
                }
                Spacer(minLength: 0)
                Button {
                    // 직접 입력한 기록이 섞였으면 한 번 더 묻는다(OVW1108A01).
                    if userOwnedCount > 0 {
                        isConfirmingUserOwned = true
                    } else {
                        submit(includesUserOwned: true)
                    }
                } label: {
                    Text(language.text("덮기", "Overwrite"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
                        .background(Color.tpAccent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(pickedCategory == nil || affectedCount == 0)
                .opacity(pickedCategory == nil || affectedCount == 0 ? 0.45 : 1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(Color.tpSurface)
    }

    private var summaryLine: String {
        guard let pickedCategory else {
            return language.text("덮을 분류를 고르세요", "Pick a category to overwrite")
        }
        return language.text(
            "클립 \(affectedCount)개를 '\(pickedCategory.localizedTitle(language))' 분류로 덮습니다",
            "Overwrites \(affectedCount) clip(s) with \(pickedCategory.localizedTitle(language))"
        )
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
            .foregroundStyle(Color.tpSecondary)
    }
}
