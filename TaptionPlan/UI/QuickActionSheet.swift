import SwiftUI

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

            HStack(spacing: TaptionSpacing.regular) {
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
                                in: RoundedRectangle(cornerRadius: TaptionRadius.small)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 14)

            HStack(spacing: TaptionSpacing.regular) {
                VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
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
                            in: RoundedRectangle(cornerRadius: TaptionRadius.control)
                        )
                        .taptionTouchTarget(visualWidth: 34, visualHeight: 34)
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
            .background(Color.tpBackground, in: RoundedRectangle(cornerRadius: TaptionRadius.tile))
            .padding(.bottom, 12)

            // 메모 입력은 하단 메뉴의 메모 추가 버튼에서 시작한다.
            HStack(spacing: TaptionSpacing.regular) {
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
                in: RoundedRectangle(cornerRadius: TaptionRadius.panel)
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
                    style == .primary ? Color.tpInk : style == .health ? Color.tpExercise : Color.tpControlFill,
                    in: RoundedRectangle(cornerRadius: TaptionRadius.panel)
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
