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

    var id: String { rawValue }

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .wholeDay: language.text("하루 전체", "Whole day")
        case .sameCategory: language.text("같은 분류만", "Same category")
        }
    }

    func explanation(_ language: MapHomeLanguage) -> String {
        switch self {
        case .wholeDay:
            language.text(
                "기록이 있는 클립을 모두 바꿉니다. 기록이 없는 시간은 미확인으로 남습니다.",
                "Every recorded clip changes. Hours without a record stay unconfirmed."
            )
        case .sameCategory:
            language.text(
                "지금 고른 클립과 같은 분류인 클립만 바꿉니다.",
                "Only clips in the same category as the selected clip change."
            )
        }
    }
}

/// 창이 화면에 넘기는 요청. 분류가 없으면 합치기만 한다.
struct NLEOverwriteRequest: Equatable {
    let category: MapHomeSidebarMajorCategory?
    let scope: NLEOverwriteScope
    let mergesAfter: Bool
}

/// 덮기·합치기 계산. 창이 보여 주는 수와 화면이 실제로 바꾸는 수가 같도록 한 곳에 모은다.
enum NLEOverwritePolicy {
    struct Result: Equatable {
        var track: NLETrack
        var changed: Int
        var merged: Int
    }

    /// 덮으면 바뀌는 클립 수. 원본 기록이 없는 빈 시간은 세지 않는다.
    static func affectedCount(
        _ track: NLETrack,
        scope: NLEOverwriteScope,
        selectedCategoryID: String?
    ) -> Int {
        track.clips.filter { clip in
            guard !clip.parent.sourceIDs.isEmpty else { return false }
            return scope == .wholeDay || clip.option.categoryID == selectedCategoryID
        }.count
    }

    /// 지금 맞닿은 같은 분류를 합치면 줄어드는 클립 수.
    static func mergeableCount(_ track: NLETrack) -> Int {
        var copy = track
        return copy.mergeAdjacent()
    }

    static func apply(
        _ track: NLETrack,
        option: ActivityCorrectionOption?,
        scope: NLEOverwriteScope,
        selectedCategoryID: String?,
        mergesAfter: Bool
    ) -> Result {
        var next = track
        var changed = 0
        if let option {
            changed = next.overwrite(
                with: option,
                matchingCategoryID: scope == .sameCategory ? selectedCategoryID : nil
            )
        }
        // 분류를 고르지 않았으면 합치기만 하는 요청이다.
        let merged = mergesAfter || option == nil ? next.mergeAdjacent() : 0
        return Result(track: next, changed: changed, merged: merged)
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
    /// 지금 고른 클립의 분류. '같은 분류만'의 기준이다.
    let selectedCategoryID: String?
    let categories: [MapHomeSidebarMajorCategory]
    var onApply: (NLEOverwriteRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scope: NLEOverwriteScope = .wholeDay
    @State private var mergesAfter = true
    @State private var pickedCategoryID: String?

    private var pickedCategory: MapHomeSidebarMajorCategory? {
        categories.first { $0.id == pickedCategoryID }
    }

    private var affectedCount: Int {
        NLEOverwritePolicy.affectedCount(
            track,
            scope: scope,
            selectedCategoryID: selectedCategoryID
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
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(language.text("전체 덮기", "Overwrite all"))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(19)), weight: .bold, design: .rounded))
                Text(language.text(
                    "나뉜 클립을 한 번에 같은 분류로 바꿉니다",
                    "Change every split clip to one category at once"
                ))
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium, design: .rounded))
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
                ForEach(NLEOverwriteScope.allCases) { option in
                    Text("\(option.title(language)) \(count(for: option))").tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(Color.tpAccent)
            Text(scope.explanation(language))
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func count(for scope: NLEOverwriteScope) -> Int {
        NLEOverwritePolicy.affectedCount(
            track,
            scope: scope,
            selectedCategoryID: selectedCategoryID
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
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold, design: .rounded))
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
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
            }
            .tint(Color.tpAccent)
            .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
            Text(language.text(
                "손으로 가른 클립을 하나로 되돌립니다. 지금 합칠 수 있는 곳 \(mergeableCount)군데.",
                "Joins the clips you split by hand. \(mergeableCount) place(s) can merge now."
            ))
            .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium, design: .rounded))
            .foregroundStyle(Color.tpSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Text(summaryLine)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold, design: .rounded))
                .foregroundStyle(pickedCategory == nil ? Color.tpSecondary : Color.tpAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if mergeableCount > 0 {
                    Button {
                        onApply(NLEOverwriteRequest(category: nil, scope: scope, mergesAfter: true))
                        dismiss()
                    } label: {
                        Text(language.text("합치기만", "Merge only"))
                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold, design: .rounded))
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
                    guard let pickedCategory else { return }
                    onApply(NLEOverwriteRequest(category: pickedCategory, scope: scope, mergesAfter: mergesAfter))
                    dismiss()
                } label: {
                    Text(language.text("덮기", "Overwrite"))
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold, design: .rounded))
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
            .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold, design: .rounded))
            .foregroundStyle(Color.tpSecondary)
    }
}
