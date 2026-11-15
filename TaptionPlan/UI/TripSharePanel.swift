import SwiftUI
import TaptionPlanStore
import TaptionTripShare

// 묶음 A(TSH1114A26): 그 여행의 공유 판.
//
// - `TripShareHost`가 `TripSharePanel(model:language:tripID:)`으로 시트에 띄운다(초기화 인자를 바꾸지 않는다).
// - 공유 전이면 「공유 만들기」(`TripShareCreateSheet`), 참여한 여행에는 만들기가 없다(규약 6.1).
// - 공유 중이면 구역 순서: 상태 → 참여자 → 초대 → 공지(C) → 정산(C) → 주인 동작·나가기.

/// 그 여행의 공유 판.
struct TripSharePanel: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let tripID: String

    @Environment(\.dismiss) private var dismiss
    /// 만들기를 시작했으면 연결이 생긴 뒤에도 초대 안내를 다 볼 때까지 만들기 화면을 둔다.
    @State private var creating = false

    private var store: TripShareStore { .shared }
    private var trip: TravelTrip? { model.settings.travelTrips?.first { $0.id == tripID } }

    var body: some View {
        NavigationStack {
            List {
                if let trip, creating || TripShareCreation.canCreate(store: store, tripID: tripID) {
                    TripShareCreateSheet(model: model, language: language, trip: trip, started: $creating)
                } else if let link = store.link(tripID: tripID) {
                    if link.phase == .ended { ended } else { shared(link) }
                } else {
                    Section { Text(TripShareRoomText.message(TripShareRoomError.joinedTrip, language)) }
                }
            }
            .navigationTitle(language.text("여행 공유", "Share trip"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(language.text("닫기", "Close")) { dismiss() } } }
            .task(id: store.link(tripID: tripID)?.phase) {
                // 지구본에서 연 판이어도 참여자·상태가 보이게 방을 연다.
                if store.isShared(tripID) { await store.open(tripID: tripID) }
            }
        }
    }

    @ViewBuilder
    private func shared(_ link: TripShareLink) -> some View {
        if let status = statusText(link) {
            Section { Label(status, systemImage: "info.circle").font(.footnote) }
        }
        TripShareMembersView(language: language, tripID: tripID)
        if let url = TripShareRoomWork.inviteURL(store: store, tripID: tripID) {
            Section {
                ShareLink(item: url) { Label(language.text("초대 링크 보내기", "Send invite link"), systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("tripShareInvite")
            } footer: {
                Text(language.text(
                    "링크만으로는 들어올 수 없어요. 비밀번호는 링크와 다른 방법으로 따로 알려 주세요.",
                    "The link alone isn't enough to join. Send the password separately from the link."
                ))
            }
        }
        TripShareNoticeList(model: model, language: language, tripID: tripID)
        TripShareSettlementSection(model: model, language: language, tripID: tripID)
        TripShareOwnerSection(language: language, tripID: tripID) { dismiss() }
    }

    private var ended: some View {
        Section {
            Text(TripShareRoomText.ended(store.environment.sidecar.snapshot(roomID: store.link(tripID: tripID)?.roomID ?? "")?.ended, language))
            Button(language.text("확인", "OK")) {
                Task {
                    await store.forget(tripID: tripID)
                    if !TripShareCreation.canCreate(store: store, tripID: tripID) { dismiss() }
                }
            }
            .accessibilityIdentifier("tripShareEndedOK")
        }
    }

    private func statusText(_ link: TripShareLink) -> String? {
        if link.phase == .uploading { return language.text("일정을 방에 올리는 중이에요.", "Uploading plans to the room.") }
        switch store.view(tripID: tripID)?.status {
        case .offline: return TripShareText.viewOnly(language)
        case .needsRekey: return language.text("비밀번호가 바뀌었어요. 여행 화면의 띠에서 새 비밀번호를 넣어 주세요.", "The password changed. Enter the new one from the band on the trip screen.")
        case .replaced: return language.text("다른 기기에서 열려 여기서는 멈췄어요.", "Opened on another device, so it paused here.")
        case .connecting, .idle, nil: return language.text("연결하는 중…", "Connecting…")
        case .live, .ended: return nil
        }
    }
}
