import SwiftUI
import TaptionTripShare

// 묶음 A(TSH1114A26): 주인만 하는 일(내보내기·비밀번호 바꾸기·방 지우기), 참여자의 나가기, 여행을 지울 때의 방 처리.
//
// - `AppModel.deleteTravelTrip`은 지우기 전에 `tripWillDelete(model:tripID:)`를 부르고, false면 지우지 않는다.
// - 모두 세션으로 하고, 끝나면 `store.refresh(tripID:)`. 키가 바뀌면 새 뿌리 키·세대를 `store.saveSecrets`로 키체인에 적는다.
// - 방을 지우거나 나가도 이 기기의 여행(로컬 사본)은 보통 여행으로 남는다.

/// 주인만 하는 일과 여행을 지울 때의 방 처리.
@MainActor
enum TripShareOwnerActions {
    /// 스스로 나가거나 방을 지우는 중인 여행. 이 동안의 「끝남」은 알림으로 띄우지 않는다.
    private(set) static var leaving: Set<String> = []
    /// 서버에 닿지 못해 지우기를 한 번 미룬 여행. 다시 지우면 이 기기에서만 지운다.
    private static var deferred: Set<String> = []

    enum PasswordChange: Equatable {
        case done
        /// 응답을 받지 못했다. 바뀌었으면 다음 연결 때 새 비밀번호를 묻는다.
        case unconfirmed
    }

    /// 내보내기. true면 내보낸 사람이 링크와 비밀번호를 아니 비밀번호를 바꾸기를 권한다.
    static func kick(store: TripShareStore = .shared, tripID: String, member: Int) async throws -> Bool {
        let session = try await TripShareRoomWork.liveSession(store: store, tripID: tripID)
        let result = try await session.kick(member: member)
        try? await session.catchUp()
        await store.refresh(tripID: tripID)
        return result.rekeyRecommended
    }

    /// 비밀번호 바꾸기 = 키 교체(규약 15절). 다른 참여자는 새 비밀번호를 넣을 때까지 보기만 한다.
    static func changePassword(
        store: TripShareStore = .shared, tripID: String, password: String, discardingUnreadable: Bool = false,
        iterations: Int = ShareProtocolV1.pbkdf2Iterations
    ) async throws -> PasswordChange {
        let password = try TripShareRoomWork.checked(password: password)
        guard let link = store.link(tripID: tripID), link.role == .owner,
              var secrets = try store.environment.secrets.secrets(roomID: link.roomID) else { throw ShareError.ownerKeyMissing }
        let session = try await TripShareRoomWork.liveSession(store: store, tripID: tripID)
        let keys = try await TripShareRoomWork.keys(roomID: link.roomID, linkSecret: secrets.linkSecret, password: password, iterations: iterations)
        var epoch: Int?
        do {
            epoch = try await session.rotate(to: keys, discardingUnreadable: discardingUnreadable).epoch
        } catch let error as ShareError where error == .offline || error == .transport || error == .interrupted {
            // 됐는지 모른다. 바로 한 번 확인해 보고, 그것도 안 되면 다음 연결에 맡긴다.
            guard let rotated = try? await session.confirmRotation(with: keys) else { return .unconfirmed }
            guard rotated else { throw error }
            epoch = await session.view().epoch
        }
        secrets.root = keys.root
        secrets.epoch = epoch ?? secrets.epoch
        try store.saveSecrets(secrets, roomID: link.roomID)
        await store.refresh(tripID: tripID)
        return .done
    }

    /// 방을 통째로 지운다(되돌릴 수 없다). 이 기기의 여행은 보통 여행으로 남는다.
    static func deleteRoom(store: TripShareStore = .shared, tripID: String) async throws {
        try await end(store: store, tripID: tripID) { session in try await session.deleteRoom() }
    }

    /// 참여자가 방에서 나간다. 이 기기의 사본은 보통 여행으로 남는다.
    static func leave(store: TripShareStore = .shared, tripID: String) async throws {
        try await end(store: store, tripID: tripID) { session in try await session.leave() }
    }

    private static func end(store: TripShareStore, tripID: String, _ work: (ShareRoomSession) async throws -> Void) async throws {
        guard let link = store.link(tripID: tripID) else { return }
        leaving.insert(tripID)
        defer { leaving.remove(tripID) }
        if link.phase != .ended {
            do {
                try await work(try await TripShareRoomWork.liveSession(store: store, tripID: tripID))
            } catch ShareError.readOnly(.ended) {
                // 이미 끝난 방이다(지워졌거나 내보내졌다).
            } catch let error as ShareError where error.serverCode == .notFound || error.serverCode == .removed {
            }
            await TripShareRoomWork.settleEnded(store: store, tripID: tripID)
        }
        await store.forget(tripID: tripID)
    }

    /// 여행을 지우기 직전에 불린다. false를 돌려주면 지우지 않는다.
    /// 주인이면 방을 지우고 참여자면 나간다. 서버에 닿지 못하면 한 번은 멈추고 알리며, 다시 지우면 이 기기에서만 지운다
    /// (그때 방은 기한까지 서버에 남는다).
    static func tripWillDelete(model: AppModel, tripID: String) async -> Bool {
        let store = TripShareStore.shared
        guard let link = store.link(tripID: tripID) else { return true }
        do {
            switch link.role {
            case .owner: try await deleteRoom(store: store, tripID: tripID)
            case .member: try await leave(store: store, tripID: tripID)
            }
        } catch {
            guard deferred.remove(tripID) != nil else {
                deferred.insert(tripID)
                model.userFacingError = MapHomeLanguage.current.text(
                    "서버에 닿지 못해 공유를 끝내지 못했어요. 여행은 지우지 않았어요. 한 번 더 지우면 이 기기에서만 지워요.",
                    "Couldn't reach the server to end sharing, so the trip wasn't deleted. Delete again to remove it from this device only."
                )
                return false
            }
            await store.forget(tripID: tripID)
        }
        deferred.remove(tripID)
        return true
    }
}

/// 공유 판의 맨 아래 구역: 주인은 비밀번호 바꾸기·방 지우기, 참여자는 나가기.
struct TripShareOwnerSection: View {
    let language: MapHomeLanguage
    let tripID: String
    /// 방을 지웠거나 나갔을 때(공유 판을 닫는다).
    var onEnded: () -> Void = {}

    @State private var asksPassword = false
    @State private var confirmsEnd = false
    @State private var busy = false
    @State private var message: String?

    private var store: TripShareStore { .shared }
    private var isOwner: Bool { store.link(tripID: tripID)?.role == .owner }

    var body: some View {
        Section {
            if isOwner {
                Button(language.text("비밀번호 바꾸기", "Change password")) { asksPassword = true }
                    .disabled(busy || !store.canEdit(tripID))
                    .accessibilityIdentifier("tripShareChangePassword")
            }
            Button(role: .destructive) { confirmsEnd = true } label: {
                HStack {
                    Text(isOwner ? language.text("방 지우기", "Delete room") : language.text("공유에서 나가기", "Leave share"))
                    if busy { Spacer(); ProgressView() }
                }
            }
            .disabled(busy)
            .accessibilityIdentifier("tripShareEnd")
        } footer: {
            if let message { Text(message).foregroundStyle(Color.tpHoliday) }
        }
        .sheet(isPresented: $asksPassword) { TripSharePasswordSheet(language: language, tripID: tripID) }
        .confirmationDialog(
            isOwner
                ? language.text("방을 지우면 모든 사람의 공유가 끝나고 되돌릴 수 없어요. 각자 기기의 사본은 남아요.", "Deleting the room ends sharing for everyone and can't be undone. Each device keeps its copy.")
                : language.text("나가면 더는 함께 볼 수 없어요. 이 기기의 사본은 남아요.", "After leaving you no longer sync. The copy on this device stays."),
            isPresented: $confirmsEnd, titleVisibility: .visible
        ) {
            Button(isOwner ? language.text("방 지우기", "Delete room") : language.text("나가기", "Leave"), role: .destructive) { end() }
            Button(language.text("취소", "Cancel"), role: .cancel) {}
        }
    }

    private func end() {
        busy = true
        message = nil
        let owner = isOwner
        Task {
            defer { busy = false }
            do {
                if owner { try await TripShareOwnerActions.deleteRoom(tripID: tripID) } else { try await TripShareOwnerActions.leave(tripID: tripID) }
                onEnded()
            } catch {
                message = TripShareRoomText.message(error, language)
            }
        }
    }
}

/// 주인의 비밀번호 바꾸기.
struct TripSharePasswordSheet: View {
    let language: MapHomeLanguage
    let tripID: String
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var busy = false
    @State private var message: String?
    @State private var done = false
    @State private var asksDiscard = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if done {
                        LabeledContent(language.text("새 비밀번호", "New password"), value: password)
                    } else {
                        TextField(language.text("새 비밀번호 (6자 이상)", "New password (6+ characters)"), text: $password)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("tripShareNewPassword")
                    }
                } footer: {
                    Text(message ?? (done
                        ? language.text("바꿨어요. 함께하는 사람들에게 새 비밀번호를 따로 알려 주세요. 넣을 때까지 그 사람들은 보기만 해요.", "Changed. Tell your companions the new password separately. Until they enter it, they can only view.")
                        : language.text("바꾸면 방의 내용을 새 키로 다시 잠가요. 내보낸 사람은 옛 비밀번호로 더는 들어오지 못해요.", "Changing it re-locks the room with a new key. Anyone you removed can no longer get in with the old password.")))
                        .foregroundStyle(message == nil ? Color.secondary : Color.tpHoliday)
                }
                Section {
                    if done {
                        Button(language.text("완료", "Done")) { dismiss() }
                    } else {
                        Button { submit(discarding: false) } label: {
                            HStack {
                                Text(busy ? language.text("바꾸는 중…", "Changing…") : language.text("바꾸기", "Change"))
                                if busy { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(busy || SharePasswordPolicy.issue(in: password) != nil)
                        .accessibilityIdentifier("tripShareNewPasswordSubmit")
                    }
                }
            }
            .navigationTitle(language.text("비밀번호 바꾸기", "Change password"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(language.text("닫기", "Close")) { dismiss() } } }
            .confirmationDialog(
                language.text("풀지 못한 항목이 있어요. 그 항목을 버리고 바꿀까요?", "Some items can't be read. Discard them and change the password?"),
                isPresented: $asksDiscard, titleVisibility: .visible
            ) {
                Button(language.text("버리고 바꾸기", "Discard and change"), role: .destructive) { submit(discarding: true) }
                Button(language.text("취소", "Cancel"), role: .cancel) {}
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(busy)
    }

    private func submit(discarding: Bool) {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                switch try await TripShareOwnerActions.changePassword(tripID: tripID, password: password, discardingUnreadable: discarding) {
                case .done: done = true
                case .unconfirmed:
                    message = language.text(
                        "바뀌었는지 확인하지 못했어요. 다시 연결됐을 때 새 비밀번호를 물으면 방금 정한 것을 넣어 주세요.",
                        "Couldn't confirm the change. If you're asked for a new password after reconnecting, enter the one you just chose."
                    )
                }
            } catch ShareError.unreadableItems {
                asksDiscard = true
            } catch {
                message = TripShareRoomText.message(error, language)
            }
        }
    }
}
