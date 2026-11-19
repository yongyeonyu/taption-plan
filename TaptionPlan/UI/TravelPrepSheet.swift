import SwiftUI
import TaptionPlanStore

/// 여행 준비물 카드 목록(FLT1119A01): eSIM·숙소 예약·면세 주문. 계획표 열이 아니라 여행 상세의 별도 목록이다.
/// 알림(문자·알림톡)에서 읽어 만든 카드와 그 상태(접수·확정·수령)를 보고, 확인 표시와 개통·바우처 링크를 쓴다.
struct TravelPrepSheet: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let trip: TravelTrip

    @Environment(\.dismiss) private var dismiss

    private var items: [TravelPrepItem] {
        (model.settings.travelPrepItems ?? []).filter { $0.tripID == trip.id }.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    Section {
                        Text(language.text("아직 준비물이 없어요. eSIM·숙소·면세점 알림을 붙여넣거나 단축어로 넘기면 여기에 쌓여요.", "No prep items yet. Paste or share eSIM, lodging, or duty-free notices and they will collect here."))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(items) { item in
                    row(item)
                }
                .onDelete { offsets in
                    let ids = offsets.map { items[$0].id }
                    Task { for id in ids { _ = await model.deleteTravelPrep(id) } }
                }
            }
            .navigationTitle(language.text("준비물", "Prep items"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(language.text("닫기", "Close")) { dismiss() } } }
        }
        .accessibilityIdentifier("travelPrepSheet")
    }

    private func row(_ item: TravelPrepItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { Task { _ = await model.setTravelPrepChecked(item.id, item.checked != true) } } label: {
                Image(systemName: item.checked == true ? "checkmark.circle.fill" : "circle").font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.checked == true ? language.text("완료됨", "Done") : language.text("완료로 표시", "Mark as done"))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.body.weight(.semibold)).strikethrough(item.checked == true)
                if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: 6) {
                    if let status = statusText(item) { tag(status) }
                    if item.isBusiness == true { tag(language.text("출장", "Business")) }
                    if item.needsDateConfirmation == true { tag(language.text("날짜 확인 필요", "Confirm dates"), warning: true) }
                }
                if let link = item.linkURL, let url = URL(string: link) {
                    Link(language.text("개통·바우처 열기", "Open activation or voucher"), destination: url).font(.caption)
                }
            }
        }
    }

    private func statusText(_ item: TravelPrepItem) -> String? {
        switch item.orderStatus {
        case "tentative": language.text("접수", "Received")
        case "booked": language.text("확정", "Confirmed")
        case "received": language.text("수령", "Picked up")
        default: nil
        }
    }

    private func tag(_ text: String, warning: Bool = false) -> some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(warning ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.18), in: Capsule())
    }
}
