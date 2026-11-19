import SwiftUI

/// 메모 한 칸. 기간이 지나면(`readOnlyAfter`) 입력·저장·지우기가 막히고 읽기만 된다.
struct SeasonPackMemoView: View {
    let center: SeasonPackCenter
    let packID: String
    let itemID: String
    let label: String
    let maxLength: Int
    let readOnlyAfter: String?
    let language: String
    @State private var text = ""
    @State private var isLocked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !label.isEmpty { Text(label).font(.footnote).foregroundStyle(.secondary) }
            TextField(SeasonPackText.ui("메모를 적어 보세요", "Write a note", language: language), text: $text, axis: .vertical)
                .lineLimit(1...5)
                .disabled(isLocked)
                .onChange(of: text) { _, value in
                    if value.count > maxLength { text = String(value.prefix(maxLength)); return }
                    save(value)
                }
            HStack {
                Text("\(text.count)/\(maxLength)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                if isLocked {
                    Label(SeasonPackText.ui("기간이 지나 읽기만 돼요", "Read-only now", language: language), systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !text.isEmpty {
                    Button(SeasonPackText.ui("지우기", "Clear", language: language), role: .destructive) { clear() }.font(.caption)
                }
            }
        }
        .onAppear {
            isLocked = lockState()
            text = center.memoStore?.load(packID: packID, itemID: itemID)?.text ?? ""
        }
    }

    private func lockState() -> Bool {
        SeasonPackMemoStore.isReadOnly(readOnlyAfter: readOnlyAfter, now: center.host?.now() ?? Date(), calendar: center.calendar)
    }

    private func save(_ value: String) {
        guard !isLocked else { return }
        _ = try? center.memoStore?.save(value, packID: packID, itemID: itemID, maxLength: maxLength, readOnlyAfter: readOnlyAfter, now: center.host?.now() ?? Date(), calendar: center.calendar)
    }

    private func clear() {
        text = ""
        try? center.memoStore?.delete(packID: packID, itemID: itemID, readOnlyAfter: readOnlyAfter, now: center.host?.now() ?? Date(), calendar: center.calendar)
    }
}
