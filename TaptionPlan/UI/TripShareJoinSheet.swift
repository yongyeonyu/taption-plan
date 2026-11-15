import SwiftUI
import TaptionTripShare

// 묶음 A(TSH1114A26): 초대로 참여.
//
// - `TripShareHost`가 `TripShareJoinSheet(model:language:invite:)`으로 띄운다. 열린 주소로 왔으면 `invite`가 있고,
//   목록의 참여 단추로 왔으면 nil이라 붙여넣기(`PasteButton`)부터 받는다.
// - 순서: 링크 확인 → 비밀번호 → 닉네임 → 키 유도 → 입장 → 연결을 적음 → 방을 열고 내 카드를 올림.
// - 로컬 여행과 일정은 B의 `TripSharePlanProjector`가 방 내용을 받아 만든다(여기서 만들지 않는다).

/// 입장. 화면 없이도 돌게 따로 둔다.
@MainActor
enum TripShareJoining {
    /// 입장하고 그 여행의 로컬 번호를 돌려준다. 방은 열린 채로 둔다(방 내용이 로컬에 투영되게).
    @discardableResult
    static func join(
        store: TripShareStore = .shared, invite: ShareInvite, password: String, nickname: String,
        iterations: Int = ShareProtocolV1.pbkdf2Iterations
    ) async throws -> String {
        guard let transport = store.environment.transport else { throw TripShareRoomError.unavailable }
        let password = try TripShareRoomWork.checked(password: password)
        let nickname = try TripShareRoomWork.cleaned(nickname: nickname)
        if let old = store.link(roomID: invite.roomID) {
            guard old.phase == .ended else { throw TripShareRoomError.alreadyJoined }
            // 나갔거나 내보내진 방에 다시 들어온다. 옛 연결을 먼저 치운다.
            await store.forget(tripID: old.tripID)
        }
        let keys = try await TripShareRoomWork.keys(roomID: invite.roomID, linkSecret: invite.linkSecret, password: password, iterations: iterations)
        let entry = try await ShareRoomClient.join(transport: transport, roomID: invite.roomID, proof: keys.proof)
        let tripID = TripShareMapping.joinedTripID(roomID: invite.roomID)
        TripShareRoomWork.savedNickname = nickname
        try store.register(
            TripShareLink(roomID: invite.roomID, tripID: tripID, role: .member, phase: .sharing),
            secrets: ShareRoomSecrets(root: keys.root, linkSecret: invite.linkSecret, token: entry.token, member: entry.member, epoch: entry.epoch)
        )
        // 입장은 됐다. 카드 올리기가 끊기면 다음에 방을 열 때 `ensureCard`가 잇는다.
        if let session = try? await TripShareRoomWork.liveSession(store: store, tripID: tripID) {
            try? await session.catchUp()
            _ = try? await session.publish(card: TripShareRoomWork.card(nickname: nickname, member: entry.member))
            await store.refresh(tripID: tripID)
        }
        return tripID
    }
}

/// 초대로 참여.
struct TripShareJoinSheet: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let invite: ShareInvite?

    @Environment(\.dismiss) private var dismiss
    @State private var pasted: ShareInvite?
    @State private var linkText = ""
    @State private var password = ""
    @State private var nickname = TripShareRoomWork.savedNickname
    @State private var busy = false
    @State private var message: String?

    private var current: ShareInvite? { invite ?? pasted }

    var body: some View {
        NavigationStack {
            Form {
                linkSection
                Section {
                    SecureField(language.text("비밀번호", "Password"), text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("tripShareJoinPassword")
                    TextField(language.text("내 닉네임", "My nickname"), text: $nickname)
                        .accessibilityIdentifier("tripShareJoinNickname")
                } footer: {
                    Text(message ?? language.text("비밀번호는 초대한 사람에게 따로 물어봐 주세요.", "Ask the person who invited you for the password."))
                        .foregroundStyle(message == nil ? Color.secondary : Color.tpHoliday)
                }
                Section {
                    Button { submit() } label: {
                        HStack {
                            Text(busy ? language.text("들어가는 중…", "Joining…") : language.text("참여하기", "Join"))
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || current == nil || password.isEmpty || nickname.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("tripShareJoinSubmit")
                }
            }
            .navigationTitle(language.text("초대로 참여", "Join by invite"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(language.text("닫기", "Close")) { dismiss() } } }
        }
    }

    @ViewBuilder
    private var linkSection: some View {
        Section {
            if current != nil {
                Label(language.text("초대 링크를 확인했어요.", "Invite link confirmed."), systemImage: "checkmark.circle.fill")
                    .accessibilityIdentifier("tripShareJoinLinkOK")
            }
            if invite == nil {
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    Task { @MainActor in read(text) }
                }
                .buttonBorderShape(.capsule)
                TextField(language.text("받은 초대 링크", "Invite link you received"), text: $linkText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { read(linkText) }
                    .accessibilityIdentifier("tripShareJoinLink")
            }
        } header: {
            Text(language.text("초대 링크", "Invite link"))
        }
    }

    private func read(_ text: String) {
        pasted = TripShareEnvironment.invite(from: text)
        // 링크의 비밀 값이 화면에 남지 않게 읽은 뒤 지운다.
        linkText = ""
        message = pasted == nil ? TripShareRoomText.message(TripShareRoomError.badInvite, language) : nil
    }

    private func submit() {
        guard let current else { return }
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                try await TripShareJoining.join(invite: current, password: password, nickname: nickname)
                dismiss()
            } catch {
                message = TripShareRoomText.message(error, language)
            }
        }
    }
}
