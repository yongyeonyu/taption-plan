import Charts
import SwiftUI

extension ReviewView {
    // MARK: - 메모

    var memoBreakdownCard: some View {
        let memos = content.contexts.filter { $0.symbolName == "note.text" }

        return VStack(alignment: .leading, spacing: TaptionSpacing.regular) {
            Label("메모", systemImage: "note.text")
                .font(.taption(size: 11, weight: .bold))

            if memos.isEmpty {
                Text("이 기간에 작성된 메모가 없습니다.")
                    .font(.taption(size: 10.5))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                ForEach(memos) { memo in
                    HStack(alignment: .top, spacing: TaptionSpacing.cozy) {
                        Image(systemName: "note.text")
                            .font(.taption(size: 11))
                            .foregroundStyle(Color.tpStudyDark)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(memo.text)
                                .font(.taption(size: 10, weight: .medium))
                                .lineLimit(3)
                            Text(
                                memo.date.formatted(
                                    date: .omitted,
                                    time: .shortened
                                )
                            )
                            .font(.taption(size: 8.5))
                            .foregroundStyle(Color.tpSecondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .tpCardSurface(radius: 13, tint: .tpSurfacePink)
    }

    // MARK: - 계층형 기록

    var recordHierarchyCard: some View {
        let groups = hierarchyGroups
        return VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
            HStack(alignment: .firstTextBaseline) {
                Label("실제 기록", systemImage: "checkmark.circle")
                    .font(.taption(size: 11, weight: .bold))
                Spacer()
                Text(
                    model.reviewScale == .day || model.reviewScale == .week
                        ? "\(groups.count)개 일과 · \(childCount)개 상세활동"
                        : "\(childCount)개 항목"
                )
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
            }

            if groups.isEmpty {
                Text("이 기간에 저장된 실제 데이터가 없습니다.")
                    .font(.taption(size: 10.5))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                ForEach(groups) { group in
                    categorySection(group)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .tpCardSurface(radius: 13, tint: .tpSurfaceSage)
    }

    var childCount: Int {
        hierarchyGroups.reduce(0) { $0 + $1.children.count }
    }

    var hierarchyGroups: [RecordCategoryGroup] {
        model.reviewScale == .day || model.reviewScale == .week
            ? content.phaseGroups
            : content.groups
    }

    @ViewBuilder
    func categorySection(_ group: RecordCategoryGroup) -> some View {
        let isExpanded = !collapsedGroupIDs.contains(group.id)
        VStack(alignment: .leading, spacing: 2) {
            Button {
                clearClockHighlight()
                if isExpanded {
                    collapsedGroupIDs.insert(group.id)
                } else {
                    collapsedGroupIDs.remove(group.id)
                }
            } label: {
                HStack(spacing: TaptionSpacing.snug) {
                    Image(systemName: "chevron.down")
                        .accessibilityHidden(true)
                        .font(.taption(size: 8, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .frame(width: 10)
                    Image(systemName: symbolName(group))
                        .font(.taption(size: 11, weight: .semibold))
                        .foregroundStyle(color(forCategoryID: group.id))
                        .frame(width: 15)
                    Text(displayedGroupName(group))
                        .font(.taption(size: 11, weight: .bold))
                        .foregroundStyle(Color.tpInk)
                    Spacer(minLength: 4)
                    Text(groupTotalText(group))
                        .font(.taption(size: 10, weight: .semibold))
                        .foregroundStyle(color(forCategoryID: group.id))
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                highlightedCategoryID == group.id
                    ? color(forCategoryID: group.id).opacity(0.09)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: TaptionRadius.tight)
            )

            if isExpanded {
                ForEach(group.children) { child in
                    childRow(child, in: group)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }

    func childRow(
        _ child: RecordGroupChild,
        in group: RecordCategoryGroup
    ) -> some View {
        Button {
            clearClockHighlight()
            model.detail = .actual(child.recordID)
        } label: {
            HStack(spacing: TaptionSpacing.cozy) {
                if let tokenData = appUsageTokenData(for: child, in: group) {
                    // 어플 기록만 시스템이 그리는 실제 앱 이름·아이콘을 쓴다.
                    AppUsageNameLabel(tokenData: tokenData, size: 10)
                } else {
                    HStack(spacing: TaptionSpacing.compact) {
                        Image(systemName: childSymbolName(child, in: group))
                            .font(.taption(size: 9, weight: .semibold))
                            .foregroundStyle(color(forCategoryID: group.id))
                            .frame(width: 14)
                        Text(child.title)
                            .font(.taption(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                }
                if child.occurrenceCount > 1 {
                    Text("\(child.occurrenceCount)회")
                        .font(.taption(size: 8))
                        .foregroundStyle(Color.tpSecondary)
                }
                Spacer(minLength: 4)
                Text(
                    child.start.formatted(date: .omitted, time: .shortened)
                )
                .font(.taption(size: 8))
                .foregroundStyle(Color.tpSecondary)
                Text(DurationText.koreanAtLeastAMinute(child.duration))
                    .font(.taption(size: 9, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(minWidth: 52, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.taption(size: 7, weight: .bold))
                    .foregroundStyle(Color.tpSecondary.opacity(0.7))
            }
            .padding(.leading, 31)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(displayedGroupName(group)) \(child.title) \(DurationText.koreanAtLeastAMinute(child.duration))"
        )
    }

    func childSymbolName(
        _ child: RecordGroupChild,
        in group: RecordCategoryGroup
    ) -> String {
        if let actual = model.snapshot.actuals.first(where: {
            $0.id == child.recordID
        }) {
            if let behavior = actual.behavior,
               let kind = WatchBehaviorKind.fromModelLabel(behavior) {
                return kind.systemImage
            }
            return ActivityCorrectionCatalog.activitySystemImage(
                title: actual.title,
                behavior: actual.behavior,
                categoryID: group.id
            )
        }
        return ActivityCorrectionCatalog.activitySystemImage(
            title: child.title,
            behavior: nil,
            categoryID: group.id
        )
    }

    func displayedGroupName(_ group: RecordCategoryGroup) -> String {
        group.id == "activity" ? "상세활동" : group.name
    }

    func appUsageTokenData(
        for child: RecordGroupChild,
        in group: RecordCategoryGroup
    ) -> Data? {
        guard group.id == "appUsage" else { return nil }
        let data = model.appUsageTokenIndex[child.recordID]
        return AppUsageNameLabel.canRender(data) ? data : nil
    }

    func groupTotalText(_ group: RecordCategoryGroup) -> String {
        let total = DurationText.korean(group.duration)
        guard group.id == "movement",
              let dominant = group.dominantChildTitle,
              group.children.count > 1 else {
            return total
        }
        return "\(total) · \(dominant)"
    }

    // MARK: - 맥락

    var contextCard: some View {
        let contexts = content.contexts.filter {
            $0.symbolName != "note.text"
        }
        return VStack(alignment: .leading, spacing: TaptionSpacing.cozy) {
            Text("이 기간을 설명한 기록")
                .font(.taption(size: 11, weight: .bold))
            if contexts.isEmpty {
                contextLine(
                    "tray",
                    "사진·날씨가 연결되면 이번 기간의 맥락을 보여드립니다."
                )
            } else {
                ForEach(contexts) { context in
                    contextLine(context.symbolName, context.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .tpCardSurface(radius: 13, tint: .tpSurfaceLavender)
    }

    func contextLine(_ image: String, _ text: String) -> some View {
        HStack(spacing: TaptionSpacing.cozy) {
            Image(systemName: image)
                .font(.taption(size: 13))
                .foregroundStyle(Color.tpSecondary)
                .frame(width: 14)
            Text(text)
                .font(.taption(size: 10.5))
        }
    }
}
