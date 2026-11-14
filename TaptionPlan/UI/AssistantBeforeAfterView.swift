import SwiftUI

/// 「AI가 정리한 N건」 배너(ABA1114A15). 그날 기록에 반영된 것이 없으면 보이지 않는다. 누르면 전·후 카드 목록이 뜬다.
struct AssistantBeforeAfterBanner: View {
    let language: MapHomeLanguage
    let day: Date
    let log: [AssistantLogEntry]
    /// 목록을 닫을 때. 되돌린 것이 있을 수 있어 부른 쪽이 기록을 다시 읽는다.
    let onClose: () -> Void
    @State private var isOpen = false

    var body: some View {
        let digest = AssistantDigest.day(log, on: day)
        if digest.count > 0 {
            Button { isOpen = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.tpAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AssistantDigest.headline(digest.count, language: language))
                            .font(.taptionStyle(.subheadline, weight: .semibold))
                            .foregroundStyle(Color.tpInk)
                        Text(AssistantDigest.breakdown(digest, language: language))
                            .font(.taptionStyle(.caption2))
                            .foregroundStyle(Color.tpSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                }
                .padding(10)
                .background(Color.tpCard.opacity(0.9), in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint(language.text("전·후 비교 보기", "Show before and after"))
            .sheet(isPresented: $isOpen, onDismiss: onClose) {
                AssistantBeforeAfterList(language: language, day: day, model: AssistantCommandRefresh.model)
            }
        }
    }
}

/// 그날 AI가 정리한 것의 전·후 카드 목록. 되돌리기는 「AI가 한 일」과 같은 `undoAssistantEntry`만 쓴다.
struct AssistantBeforeAfterList: View {
    let language: MapHomeLanguage
    let day: Date
    let model: AppModel?
    @State private var digest = AssistantDigest.Day()
    @State private var workingID: UUID?
    @State private var failedIDs: Set<UUID> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AssistantDigest.undoLine(digest, language: language))
                            .font(.taptionStyle(.footnote, weight: .medium))
                            .foregroundStyle(Color.tpInk)
                        Text(language.text(
                            "AI는 표시와 교정만 바꿔요. 센서가 남긴 원본 기록은 그대로 있어요.",
                            "The AI only changes labels and corrections. Original sensor records stay as they were."
                        ))
                        .font(.taptionStyle(.caption))
                        .foregroundStyle(Color.tpSecondary)
                    }
                    ForEach(digest.items) { item in
                        AssistantBeforeAfterCard(
                            item: item, language: language, canUndo: model != nil && workingID == nil, failed: failedIDs.contains(item.id)
                        ) { undo(item.entry) }
                    }
                }
                .padding(16)
            }
            .background(Color.tpSurface)
            .navigationTitle(AssistantDigest.headline(digest.count, language: language))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("닫기", "Close")) { dismiss() }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        let next = AssistantDigest.day(AssistantActionLog.load(), on: day)
        if next != digest { digest = next }
    }

    private func undo(_ entry: AssistantLogEntry) {
        guard workingID == nil, let model else { return }
        workingID = entry.id
        Task { @MainActor in
            defer { workingID = nil }
            if await model.undoAssistantEntry(entry) {
                AssistantActionLog.markUndone(entry.id)
                failedIDs.remove(entry.id)
                reload()
            } else {
                failedIDs.insert(entry.id)
            }
        }
    }
}

/// 한 건의 전·후 카드: 무엇을, 전, 후, 어느 AI가, 되돌리기 상태.
struct AssistantBeforeAfterCard: View {
    let item: AssistantDigest.Item
    let language: MapHomeLanguage
    let canUndo: Bool
    let failed: Bool
    let onUndo: () -> Void

    private var entry: AssistantLogEntry { item.entry }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(entry.kind.title(language), systemImage: item.group.symbol)
                    .font(.taptionStyle(.subheadline, weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                Spacer(minLength: 0)
                Text(entry.appliedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.taptionStyle(.caption2))
                    .foregroundStyle(Color.tpSecondary)
            }
            side(language.text("전", "Before"), entry.before.isEmpty ? language.text("새로", "New") : entry.before, isAfter: false)
            side(language.text("후", "After"), entry.after, isAfter: true)
            if let connection = AssistantConnectionName.shown(entry) {
                Text(language.text("보낸 연결: \(connection)", "From: \(connection)"))
                    .font(.taptionStyle(.caption2))
                    .foregroundStyle(Color.tpSecondary)
            }
            footer
        }
        .padding(12)
        .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
    }

    private func side(_ label: String, _ text: String, isAfter: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.taptionStyle(.caption2, weight: .semibold))
                .foregroundStyle(isAfter ? Color.tpAccent : Color.tpSecondary)
                .frame(minWidth: 28, alignment: .leading)
            Text(text)
                .font(.taptionStyle(.footnote))
                .foregroundStyle(isAfter ? Color.tpInk : Color.tpSecondary)
                // 되돌린 것은 「후」에 줄을 그어 지금은 「전」 상태임을 보인다.
                .strikethrough(isAfter && item.state == .undone)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var footer: some View {
        switch item.state {
        case .undone:
            Text(language.text("되돌렸어요", "Undone")).font(.taptionStyle(.caption)).foregroundStyle(Color.tpSecondary)
        case .irreversible:
            Text(language.text("되돌릴 수 없는 일이에요", "This can't be undone")).font(.taptionStyle(.caption)).foregroundStyle(Color.tpSecondary)
        case .undoable:
            Button(action: onUndo) {
                Label(language.text("원래대로 되돌리기", "Restore original"), systemImage: "arrow.uturn.backward")
                    .font(.taptionStyle(.caption, weight: .semibold))
                    .foregroundStyle(Color.tpAccent)
            }
            .buttonStyle(.plain)
            .disabled(!canUndo)
            if failed {
                Text(language.text("그 뒤에 바뀐 내용이 있어 되돌리지 못했어요.", "It changed afterwards, so it couldn't be undone."))
                    .font(.taptionStyle(.caption))
                    .foregroundStyle(Color.tpHoliday)
            }
        }
    }
}
