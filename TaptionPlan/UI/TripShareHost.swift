import SwiftUI
import TaptionTripShare

// 묶음 A가 채운다(TSH1114A26). 0단계는 컴파일되는 뼈대와 아래 약속만 둔다.
//
// 0단계가 약속한 것
// - `TravelModeView`는 본문에 `.tripShare(model:language:openedID:route:)` 한 줄로 이 수정자를 붙인다(초기화 인자를 바꾸지 않는다).
// - `route`는 여행 화면의 상태 하나다. 머리줄 공유 단추가 `.panel(tripID:)`, 목록의 참여 단추가 `.join(nil)`을 넣는다.
// - 열린 주소로 온 초대는 `TripShareInbox.shared.pending`에 있다. 여기서 꺼내 `.join(invite)`로 바꾼다.
// - 방은 `TripShareStore.shared.open(tripID:)`·`close(tripID:)`로만 열고 닫는다. 상태는 `store.view(tripID:)?.status`,
//   안내 글은 `store.notice`(띄운 뒤 nil), 끝남은 `store.link(tripID:)?.phase == .ended`.
// - `TripShareStatusBand`는 여행 머리줄의 돈 줄 아래에 이미 놓여 있다(오프라인·비밀번호 바뀜·공유 끝남 한 줄 띠).
//
// A가 할 일: 상태 띠 내용, 비밀번호 바뀜(`needsRekey`) → 다시 증명, 끝남 알림, 앱이 뒤로 갈 때 닫기.

/// 여행 화면에 붙는 공유의 뿌리: 시트를 띄우고, 보고 있는 여행의 방을 열고 닫는다.
struct TripShareHost: ViewModifier {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    /// 지금 열어 둔 여행(지구본이면 nil).
    let openedID: String?
    @Binding var route: TripShareRoute?

    private var store: TripShareStore { .shared }
    private var inbox: TripShareInbox { .shared }

    func body(content: Content) -> some View {
        content
            .sheet(item: $route) { route in
                switch route {
                case .panel(let tripID): TripSharePanel(model: model, language: language, tripID: tripID)
                case .join(let invite): TripShareJoinSheet(model: model, language: language, invite: invite)
                }
            }
            .onChange(of: inbox.pending, initial: true) { _, invite in
                guard let invite, store.isAvailable else { return }
                inbox.pending = nil
                route = .join(invite)
            }
            .task(id: openedID) {
                guard let openedID, store.isShared(openedID) else { return }
                await store.open(tripID: openedID)
            }
            .alert(store.notice ?? "", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
                Button(language.text("확인", "OK")) { store.notice = nil }
            }
    }
}

/// 여행 머리줄 아래의 한 줄 띠: 오프라인(보기만)·비밀번호 바뀜·공유 끝남. 공유하지 않는 여행이면 아무것도 그리지 않는다.
struct TripShareStatusBand: View {
    let language: MapHomeLanguage
    let tripID: String

    var body: some View {
        // A가 `TripShareStore.shared.view(tripID:)?.status`를 읽어 채운다.
        EmptyView()
    }
}
