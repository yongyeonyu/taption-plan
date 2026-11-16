import SwiftUI

struct GoalActionLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let goal: PlanRecord

    private var existingChildIDs: Set<UUID> {
        Set(
            ((try? PlanHierarchy.descendants(
                of: goal.id,
                in: model.snapshot.plans
            )) ?? []).map(\.id)
        )
    }

    private var candidates: [PlanRecord] {
        model.snapshot.plans
            .filter { plan in
                !existingChildIDs.contains(plan.id)
                    && plan.id != goal.id
                    && plan.origin != .repeatRule
                    && !plan.isFixed
                    && plan.status != .skipped
                    && !GoalRecordPolicy.isGoal(plan)
                    && plan.categoryID != "event"
                    && plan.span.intersection(with: goal.span) != nil
            }
            .sorted { lhs, rhs in
                if lhs.span.start == rhs.span.start {
                    return lhs.title < rhs.title
                }
                return lhs.span.start < rhs.span.start
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                        ContentUnavailableView(
                        "연결할 액션아이템이 없습니다",
                        systemImage: "link.badge.plus",
                        description: Text("루틴 기간과 겹치는 연결 가능한 액션아이템이 없습니다.")
                    )
                } else {
                    List(candidates) { plan in
Group {
                        Button {
                            dismiss()
                            Task {
                                await model.connectActionItem(
                                    plan.id,
                                    toGoal: goal.id
                                )
                            }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "circle")
                                    .font(.taption(size: 11, weight: .bold))
                                    .foregroundStyle(Color.tpSecondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(plan.title)
                                        .font(.taption(size: 10.5, weight: .semibold))
                                        .foregroundStyle(Color.tpInk)
                                    Text(
                                        "\(plan.span.start.formatted(date: .abbreviated, time: .shortened))–\(plan.span.end.formatted(date: .omitted, time: .shortened))"
                                    )
                                    .font(.taption(size: 8))
                                    .foregroundStyle(Color.tpSecondary)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "link")
                                    .accessibilityHidden(true)
                                    .font(.taption(size: 9, weight: .bold))
                                    .foregroundStyle(Color.tpInk)
                            }
                        }
                        .buttonStyle(.plain)
                    
}
.listRowBackground(Color.tpSurface)
}
.tpListStyle()
                    .listStyle(.plain)
                }
            }
            .navigationTitle("액션아이템 연결")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Goal actions stay in the goal detail surface so the user can operate on
/// the selected goal without opening a second menu or editor first.
struct GoalActionControls: View {
    @Bindable var model: AppModel
    let goal: PlanRecord
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
            Text("루틴 제어")
                .font(.taption(size: 9, weight: .bold))
                .foregroundStyle(Color.tpSecondary)

            HStack(spacing: TaptionSpacing.compact) {
                Button {
                    Task {
                        if goal.status == .running {
                            await model.pausePlan(goal.id)
                        } else {
                            await model.startPlan(goal.id)
                        }
                    }
                } label: {
                    Label(
                        goal.status == .running ? "정지" : "시작",
                        systemImage: goal.status == .running
                            ? "pause.fill"
                            : "play.fill"
                    )
                }
                .disabled(goal.status == .completed)

                Button {
                    Task {
                        await model.performQuickAction(
                            .complete,
                            planID: goal.id
                        )
                    }
                } label: {
                    Label("완료", systemImage: "checkmark")
                }
                .disabled(goal.status == .completed)

                Button {
                    model.planEditorRequest = PlanEditorRequest(id: goal.id)
                } label: {
                    Label("편집", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("삭제", systemImage: "trash")
                }
            }
            .font(.taption(size: 8.5, weight: .bold))
            .buttonStyle(.borderedProminent)
            .tint(Color.tpPrimaryFill)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color.white,
            in: RoundedRectangle(cornerRadius: TaptionRadius.compact, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: TaptionRadius.compact, style: .continuous)
                .stroke(Color.tpLine.opacity(0.75), lineWidth: 0.5)
        }
    }
}

struct InlineMemoField: View {
    @Bindable var model: AppModel
    let planID: UUID
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    @State private var editingMemoID: UUID?

    var body: some View {
        HStack(spacing: TaptionSpacing.compact) {
            TextField("메모를 입력…", text: $text, axis: .vertical)
                .font(.taption(size: 9.5))
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .onSubmit { save() }
            if memoCount > 0 {
                Text("+\(memoCount)")
                    .font(.taption(size: 7.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.tpProjectDark, in: Capsule())
            }
            HStack(spacing: 3) {
                memoAction("저장", systemImage: "checkmark", enabled: canSave) { save() }
                memoAction("편집", systemImage: "pencil", enabled: latestMemo != nil) { edit() }
                memoAction("삭제", systemImage: "trash", enabled: latestMemo != nil, destructive: true) { delete() }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            Color.tpBackground,
            in: RoundedRectangle(cornerRadius: TaptionRadius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: TaptionRadius.control, style: .continuous)
                .stroke(Color.tpLine.opacity(0.75), lineWidth: 0.5)
        }
    }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var latestMemo: ActionMemo? {
        model.memos(for: planID).last
    }

    private var memoCount: Int {
        model.memos(for: planID).count
    }

    private func memoAction(
        _ title: String,
        systemImage: String,
        enabled: Bool,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.taption(size: 8, weight: .bold))
                .foregroundStyle(
                    enabled
                        ? (destructive ? Color.red : Color.tpInk)
                        : Color.tpSecondary.opacity(0.35)
                )
                .frame(width: 22, height: 22)
                .background(Color.tpCard.opacity(enabled ? 0.8 : 0.35), in: RoundedRectangle(cornerRadius: 5))
                // 버튼 간격이 3pt라 가로는 이웃과 겹치지 않는 만큼만 넓힌다.
                .taptionHitOutset(horizontal: 1.5, vertical: 11)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
    }

    private func edit() {
        guard let memo = latestMemo else { return }
        editingMemoID = memo.id
        text = memo.text
        isFocused.wrappedValue = true
    }

    private func save() {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let editingMemoID {
            model.updateMemo(editingMemoID, text: clean, kind: .idea)
        } else {
            model.addMemo(text: clean, kind: .idea, to: planID)
        }
        reset()
    }

    private func delete() {
        guard let memo = latestMemo else { return }
        model.deleteMemo(memo.id)
        reset()
    }

    private func reset() {
        text = ""
        editingMemoID = nil
        isFocused.wrappedValue = false
    }
}
