import SwiftUI
import TaptionTripShare

// 묶음 A(TSH1114A26): 참여자 목록과 여행 카드의 사람 수.
//
// 0단계가 약속한 것
// - `TripShareMemberBadge(tripID:language:)`는 여행 카드에 이미 놓여 있다(「사람 N」). 값은 `store.memberCount(tripID:)`.
// - `TripShareMembersView(language:tripID:)`는 공유 판의 첫 구역이다(`List` 안의 `Section`으로 그린다).
// - 읽는 값: `store.view(tripID:)?.members`(번호·접속 중), `.cards`(닉네임·색), `.isOwner`, `store.names(tripID:)`.
// - 내보내기는 `TripShareOwnerActions`가 한다.

/// 여행 카드의 「사람 N」. 공유하지 않는 여행이면 아무것도 그리지 않는다.
struct TripShareMemberBadge: View {
    let tripID: String
    let language: MapHomeLanguage

    var body: some View {
        if let count = TripShareStore.shared.memberCount(tripID: tripID) {
            Label(language.runtimeText("사람 \(count)", "\(count) people"), systemImage: "person.2.fill")
                .font(.caption2.weight(.medium))
                .accessibilityIdentifier("travelTripShareCount-\(tripID)")
        }
    }
}

/// 참여자 목록(닉네임·색·접속 중·주인 표시). 주인은 다른 사람을 내보낼 수 있다.
struct TripShareMembersView: View {
    let language: MapHomeLanguage
    let tripID: String

    @State private var kicking: ShareMember?
    @State private var busy = false
    @State private var message: String?
    @State private var suggestsPassword = false
    @State private var asksPassword = false

    private var store: TripShareStore { .shared }

    var body: some View {
        if let view = store.view(tripID: tripID) {
            let names = TripShareNames(me: view.me, cards: view.cards, guests: view.meta?.guests ?? [])
            Section {
                ForEach(view.members, id: \.no) { member in row(member, view: view, names: names) }
            } header: {
                Text(language.runtimeText("함께하는 사람 \(view.members.count)/\(view.limits.members)", "People \(view.members.count)/\(view.limits.members)"))
            } footer: {
                if let message { Text(message).foregroundStyle(Color.tpHoliday) }
            }
            .confirmationDialog(
                language.text("이 사람을 내보낼까요? 그 기기의 사본은 남아요.", "Remove this person? The copy on their device stays."),
                isPresented: Binding(get: { kicking != nil }, set: { if !$0 { kicking = nil } }), titleVisibility: .visible, presenting: kicking
            ) { member in
                Button(language.text("내보내기", "Remove"), role: .destructive) { kick(member.no) }
                Button(language.text("취소", "Cancel"), role: .cancel) {}
            }
            .alert(language.text("비밀번호를 바꿀까요?", "Change the password?"), isPresented: $suggestsPassword) {
                Button(language.text("바꾸기", "Change")) { asksPassword = true }
                Button(language.text("나중에", "Later"), role: .cancel) {}
            } message: {
                Text(language.text(
                    "내보낸 사람은 초대 링크와 비밀번호를 알고 있어요. 비밀번호를 바꾸면 다시 들어오지 못해요.",
                    "The person you removed still knows the invite link and password. Changing the password keeps them out."
                ))
            }
            .sheet(isPresented: $asksPassword) { TripSharePasswordSheet(language: language, tripID: tripID) }
        }
    }

    private func row(_ member: ShareMember, view: ShareRoomView, names: TripShareNames) -> some View {
        HStack(spacing: 10) {
            Circle().fill(view.cards[member.no].map { Color(hex: $0.color) } ?? Color.secondary.opacity(0.4)).frame(width: 14, height: 14)
            Text(names.name(.member(member.no))).lineLimit(1)
            if member.no == view.me { tag(language.text("나", "Me")) }
            if member.no == 1 { tag(language.text("만든 사람", "Creator")) }
            if member.stale == true { tag(language.text("새 비밀번호 필요", "Needs new password")) }
            Spacer(minLength: 4)
            Circle().fill(member.online ? Color.green : Color.secondary.opacity(0.3)).frame(width: 8, height: 8)
                .accessibilityLabel(member.online ? language.text("접속 중", "Online") : language.text("접속 안 함", "Offline"))
            if view.isOwner, member.no != view.me {
                Button { kicking = member } label: { Image(systemName: "person.fill.xmark") }
                    .buttonStyle(.borderless)
                    .disabled(busy || !view.canWrite)
                    .accessibilityLabel(language.text("내보내기", "Remove"))
                    .accessibilityIdentifier("tripShareKick-\(member.no)")
            }
        }
        .accessibilityIdentifier("tripShareMember-\(member.no)")
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
    }

    private func kick(_ member: Int) {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                suggestsPassword = try await TripShareOwnerActions.kick(tripID: tripID, member: member)
            } catch {
                message = TripShareRoomText.message(error, language)
            }
        }
    }
}
