import SwiftUI
import TaptionTripShare

// 묶음 A(TSH1114A26): 방의 수명 — 열고 닫기, 상태 띠, 비밀번호 바뀜 뒤 다시 증명, 끝남 알림.
//
// 0단계가 약속한 것
// - `TravelModeView`는 본문에 `.tripShare(model:language:openedID:route:)` 한 줄로 이 수정자를 붙인다(초기화 인자를 바꾸지 않는다).
// - `route`는 여행 화면의 상태 하나다. 머리줄 공유 단추가 `.panel(tripID:)`, 목록의 참여 단추가 `.join(nil)`을 넣는다.
// - 열린 주소로 온 초대는 `TripShareInbox.shared.pending`에 있다. 여기서 꺼내 `.join(invite)`로 바꾼다.
// - 방은 `TripShareStore.shared.open(tripID:)`·`close(tripID:)`로만 열고 닫는다.

/// 방 일(만들기·입장·주인 동작)이 화면에 알릴 실패. 서버가 준 실패는 `ShareError` 그대로 온다.
enum TripShareRoomError: Error, Equatable {
    case passwordTooShort(minimum: Int)
    case nicknameEmpty
    /// 앱 등록 키를 받지 못했다(등록 전이거나 인터넷 없음).
    case notRegistered
    /// 서버 주소가 없는 빌드.
    case unavailable
    case badInvite
    case alreadyJoined
    /// 참여한 여행은 다시 공유하지 못한다(규약 6.1).
    case joinedTrip
}

/// 방 일의 실패를 사용자 문구로 바꾼다. 패키지에는 문구가 없다.
enum TripShareRoomText {
    static func message(_ error: Error, _ language: MapHomeLanguage) -> String {
        if let error = error as? TripShareRoomError { return message(error, language) }
        guard let error = error as? ShareError else { return fallback(language) }
        switch error {
        case .server(let failure): return message(failure, language)
        case .offline, .transport, .interrupted, .readOnly(.offline), .readOnly(.notStarted):
            return language.text("서버에 닿지 못했어요. 인터넷 연결을 확인하고 다시 해 주세요.", "Couldn't reach the server. Check your connection and try again.")
        case .readOnly(.needsRekey):
            return language.text("비밀번호가 바뀌었어요. 새 비밀번호를 먼저 넣어 주세요.", "The password changed. Enter the new one first.")
        case .readOnly(.ended):
            return language.text("이 공유는 끝났어요.", "This share has ended.")
        case .unreadableItems:
            return language.text("풀지 못한 항목이 있어 비밀번호를 바꾸지 못했어요.", "Some items couldn't be read, so the password wasn't changed.")
        case .ownerKeyMissing:
            return language.text("방을 만든 기기에서만 할 수 있어요.", "Only the device that created the room can do this.")
        default: return fallback(language)
        }
    }

    private static func message(_ error: TripShareRoomError, _ language: MapHomeLanguage) -> String {
        switch error {
        case .passwordTooShort(let minimum):
            language.runtimeText("비밀번호는 \(minimum)자 이상으로 정해 주세요.", "Use a password of at least \(minimum) characters.")
        case .nicknameEmpty: language.text("닉네임을 적어 주세요.", "Enter a nickname.")
        case .notRegistered:
            language.text("앱 등록을 마치지 못해 방을 만들 수 없어요. 인터넷 연결을 확인해 주세요.", "Couldn't finish app registration, so the room wasn't created. Check your connection.")
        case .unavailable: language.text("이 빌드에서는 여행 공유를 쓸 수 없어요.", "Trip sharing isn't available in this build.")
        case .badInvite: language.text("초대 링크를 읽지 못했어요. 받은 링크를 통째로 붙여 넣어 주세요.", "Couldn't read the invite link. Paste the whole link you received.")
        case .alreadyJoined: language.text("이미 참여한 여행이에요.", "You've already joined this trip.")
        case .joinedTrip: language.text("참여한 여행은 다시 공유할 수 없어요.", "A trip you joined can't be shared again.")
        }
    }

    private static func message(_ failure: ShareServerError, _ language: MapHomeLanguage) -> String {
        switch failure.code {
        case .wrongPassword:
            guard let remaining = failure.detail.remaining else { return language.text("비밀번호가 맞지 않아요.", "Wrong password.") }
            return language.runtimeText("비밀번호가 맞지 않아요. \(remaining)번 더 틀리면 잠시 잠겨요.", "Wrong password. \(remaining) more tries before a short lockout.")
        case .joinLocked:
            let minutes = max(1, ((failure.detail.retryAfter ?? 60) + 59) / 60)
            return language.runtimeText("여러 번 틀려 잠겼어요. \(minutes)분 뒤에 다시 해 주세요.", "Locked after too many tries. Try again in \(minutes) min.")
        case .roomFull: return language.text("방이 가득 찼어요. 한 방에는 10명까지 들어올 수 있어요.", "The room is full. A room holds up to 10 people.")
        case .notFound: return language.text("방을 찾을 수 없어요. 지워졌거나 기한이 지났어요.", "Room not found. It was deleted or has expired.")
        case .removed: return language.text("이 방에서 나왔거나 내보내졌어요.", "You left or were removed from this room.")
        case .joinIPLimit, .rateLimited, .roomDailyLimit:
            return language.text("오늘은 더 시도할 수 없어요. 내일 다시 해 주세요.", "No more tries today. Try again tomorrow.")
        case .unavailable: return language.text("공유 서버가 아직 준비되지 않았어요.", "The sharing server isn't ready yet.")
        case .upgradeRequired: return language.text("앱을 최신 버전으로 올린 뒤 다시 해 주세요.", "Update the app and try again.")
        case .sameProof: return language.text("지금과 다른 비밀번호를 정해 주세요.", "Choose a password different from the current one.")
        case .ownerCannotLeave: return language.text("방을 만든 사람은 나갈 수 없어요. 방을 지워 주세요.", "The room's creator can't leave. Delete the room instead.")
        case .unauthorized: return language.text("앱 등록을 확인하지 못했어요. 잠시 뒤 다시 해 주세요.", "Couldn't verify app registration. Try again shortly.")
        default: return fallback(language)
        }
    }

    private static func fallback(_ language: MapHomeLanguage) -> String {
        language.text("하지 못했어요. 잠시 뒤 다시 해 주세요.", "That didn't work. Try again shortly.")
    }

    static func ended(_ reason: ShareEndReason?, _ language: MapHomeLanguage) -> String {
        switch reason {
        case .kicked: language.text("이 여행의 공유에서 내보내졌어요. 이 기기의 사본은 그대로 남아요.", "You were removed from this shared trip. The copy on this device stays.")
        case .left: language.text("공유에서 나왔어요. 이 기기의 사본은 그대로 남아요.", "You left the share. The copy on this device stays.")
        case .gone, nil: language.text("공유가 끝났어요(방이 지워졌거나 기한이 지났어요). 이 기기의 사본은 그대로 남아요.", "Sharing ended (the room was deleted or expired). The copy on this device stays.")
        }
    }
}

/// 묶음 A의 공용 일: 키 유도(화면 밖), 살아 있는 세션 얻기, 내 카드, 다시 증명.
@MainActor
enum TripShareRoomWork {
    static let nicknameKey = "TripShare.nickname"
    static let nicknameLimit = 20

    /// 마지막에 쓴 닉네임(다음 방의 기본값·끊긴 올리기를 이을 때). 비밀이 아니다.
    static var savedNickname: String {
        get { UserDefaults.standard.string(forKey: nicknameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: nicknameKey) }
    }

    static func cleaned(nickname: String) throws -> String {
        let name = String(nickname.trimmingCharacters(in: .whitespacesAndNewlines).prefix(nicknameLimit))
        guard !name.isEmpty else { throw TripShareRoomError.nicknameEmpty }
        return name
    }

    static func checked(password: String) throws -> String {
        if case .tooShort(let minimum) = SharePasswordPolicy.issue(in: password) { throw TripShareRoomError.passwordTooShort(minimum: minimum) }
        return password
    }

    /// PBKDF2 60만 회는 화면 밖에서 돈다(`nonisolated`라 주 실행기를 붙들지 않는다).
    nonisolated static func keys(roomID: String, linkSecret: Data, password: String, iterations: Int) async throws -> ShareKeys {
        try ShareKeys.derive(roomID: roomID, linkSecret: linkSecret, password: password, iterations: iterations)
    }

    /// 방을 열고 서버와 맞춰질 때까지 기다린다. 못 닿으면 `offline`, 끝났으면 `readOnly(.ended)`.
    static func liveSession(store: TripShareStore, tripID: String, timeout: Duration = .seconds(15)) async throws -> ShareRoomSession {
        guard let session = await store.open(tripID: tripID) else { throw ShareError.readOnly(.ended) }
        let deadline = ContinuousClock.now + timeout
        var restarted = false
        while ContinuousClock.now < deadline {
            switch await session.view().status {
            case .live: return session
            case .ended: throw ShareError.readOnly(.ended)
            case .needsRekey: throw ShareError.readOnly(.needsRekey)
            case .offline: throw ShareError.offline
            case .replaced, .idle:
                if !restarted { await session.start() }
                restarted = true
            case .connecting: break
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw ShareError.offline
    }

    static func card(nickname: String, member: Int, keeping old: ShareMemberCard? = nil) -> ShareMemberCard {
        let colors = TravelInk.flagHexes
        return ShareMemberCard(name: nickname, color: old?.color ?? colors[(max(member, 1) - 1) % colors.count], sent: old?.sent)
    }

    /// 내 카드가 방에 없으면 올린다(입장 직후 끊겼을 때를 잇는다). 방을 연 직후는 아직 연결 중이라
    /// 창구 값으로는 쓸 수 없다: 연결을 기다리고 방을 다 받은 뒤 세션 값으로 본다(TSA1117A01).
    static func ensureCard(store: TripShareStore, tripID: String) async {
        guard store.link(tripID: tripID)?.phase == .sharing,
              let session = try? await liveSession(store: store, tripID: tripID) else { return }
        try? await session.catchUp()
        let view = await session.view()
        guard view.canWrite, view.cards[view.me] == nil else { return }
        _ = try? await session.publish(card: card(nickname: savedNickname, member: view.me))
        await store.refresh(tripID: tripID)
    }

    /// 비밀번호가 바뀐 뒤(참여자): 새 비밀번호로 다시 증명하고 새 뿌리 키·세대를 키체인에 적는다.
    static func rekey(store: TripShareStore = .shared, tripID: String, password: String, iterations: Int = ShareProtocolV1.pbkdf2Iterations) async throws {
        guard let link = store.link(tripID: tripID), var secrets = try store.environment.secrets.secrets(roomID: link.roomID),
              let session = await store.open(tripID: tripID) else { throw ShareError.readOnly(.ended) }
        let keys = try await keys(roomID: link.roomID, linkSecret: secrets.linkSecret, password: password, iterations: iterations)
        let result = try await session.rekey(with: keys)
        secrets.root = keys.root
        secrets.epoch = result.epoch
        try store.saveSecrets(secrets, roomID: link.roomID)
        await store.refresh(tripID: tripID)
    }

    /// 세션이 「끝남」을 알린 것을 창구가 적을 때까지 잠깐 기다린다(그 뒤에 잊어야 연결이 되살아나지 않는다).
    static func settleEnded(store: TripShareStore, tripID: String) async {
        for _ in 0..<50 where store.link(tripID: tripID)?.phase != .ended { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// 이 방의 초대 주소(키체인의 링크 비밀로 다시 만든다).
    static func inviteURL(store: TripShareStore, tripID: String) -> URL? {
        guard let link = store.link(tripID: tripID), let secrets = try? store.environment.secrets.secrets(roomID: link.roomID),
              let invite = ShareInvite(roomID: link.roomID, linkSecret: secrets.linkSecret) else { return nil }
        return TripShareEnvironment.inviteURL(invite)
    }
}

/// 여행 화면에 붙는 공유의 뿌리: 시트를 띄우고, 보고 있는 여행의 방을 열고 닫는다.
struct TripShareHost: ViewModifier {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    /// 지금 열어 둔 여행(지구본이면 nil).
    let openedID: String?
    @Binding var route: TripShareRoute?
    @Environment(\.scenePhase) private var scenePhase

    private var store: TripShareStore { .shared }
    private var inbox: TripShareInbox { .shared }
    private var openedStatus: ShareSessionStatus? { openedID.flatMap { store.view(tripID: $0)?.status } }

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
            .task(id: openedID) { await enter(openedID) }
            .onChange(of: openedID) { old, new in
                guard let old, old != new else { return }
                Task { await leave(old) }
            }
            .onChange(of: scenePhase) { _, phase in
                // 뒤로 가면 소켓이 끊기므로 잠금을 풀고 닫는다. 돌아오면 보고 있던 방만 다시 연다.
                switch phase {
                case .background: Task { for link in store.links { await leave(link.tripID) } }
                case .active: Task { await enter(openedID) }
                default: break
                }
            }
            .onChange(of: openedStatus) { _, status in
                guard case .ended(let reason) = status, let openedID, !TripShareOwnerActions.leaving.contains(openedID) else { return }
                store.notice = TripShareRoomText.ended(reason, language)
            }
            .alert(store.notice ?? "", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
                Button(language.text("확인", "OK")) { store.notice = nil }
            }
    }

    private func enter(_ tripID: String?) async {
        guard let tripID, store.isShared(tripID) else { return }
        await store.open(tripID: tripID)
        if store.link(tripID: tripID)?.phase == .uploading {
            try? await TripShareCreation.upload(model: model, store: store, tripID: tripID)
        } else {
            await TripShareRoomWork.ensureCard(store: store, tripID: tripID)
        }
    }

    private func leave(_ tripID: String) async {
        guard !TripShareCreation.uploading.contains(tripID) else { return }
        await store.close(tripID: tripID)
    }
}

/// 여행 머리줄 아래의 한 줄 띠: 오프라인(보기만)·비밀번호 바뀜·다른 기기·공유 끝남. 공유하지 않는 여행이면 아무것도 그리지 않는다.
struct TripShareStatusBand: View {
    let language: MapHomeLanguage
    let tripID: String
    @State private var asksPassword = false

    private var store: TripShareStore { .shared }

    private enum Kind { case uploading, offline, needsRekey, replaced, ended }

    private var kind: Kind? {
        guard let link = store.link(tripID: tripID) else { return nil }
        if link.phase == .ended { return .ended }
        switch store.view(tripID: tripID)?.status {
        case .offline: return .offline
        case .needsRekey: return .needsRekey
        case .replaced: return .replaced
        case .ended: return .ended
        default: return link.phase == .uploading ? .uploading : nil
        }
    }

    var body: some View {
        if let kind {
            HStack(spacing: 8) {
                Image(systemName: icon(kind)).font(.caption.weight(.semibold))
                Text(text(kind)).font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                action(kind)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(TravelInk.panel, in: RoundedRectangle(cornerRadius: TaptionCorner.small))
            .overlay { RoundedRectangle(cornerRadius: TaptionCorner.small).stroke(TravelInk.border, lineWidth: TaptionBorder.width) }
            .accessibilityIdentifier("travelTripShareBand")
            .sheet(isPresented: $asksPassword) { TripShareRekeySheet(language: language, tripID: tripID) }
        }
    }

    private func icon(_ kind: Kind) -> String {
        switch kind {
        case .uploading: "arrow.up.circle"
        case .offline: "wifi.slash"
        case .needsRekey: "key.fill"
        case .replaced: "iphone.and.arrow.forward"
        case .ended: "person.2.slash"
        }
    }

    private func text(_ kind: Kind) -> String {
        switch kind {
        case .uploading: language.text("일정을 방에 올리는 중이에요.", "Uploading plans to the room.")
        case .offline: language.text("오프라인 — 보기만 할 수 있어요.", "Offline — view only.")
        case .needsRekey: language.text("비밀번호가 바뀌었어요. 새 비밀번호를 넣어야 이어서 볼 수 있어요.", "The password changed. Enter the new one to keep syncing.")
        case .replaced: language.text("다른 기기에서 열려 여기서는 멈췄어요.", "Opened on another device, so it paused here.")
        case .ended: language.text("공유가 끝났어요. 이 기기의 사본은 남아 있어요.", "Sharing ended. The copy on this device remains.")
        }
    }

    @ViewBuilder
    private func action(_ kind: Kind) -> some View {
        switch kind {
        case .needsRekey:
            Button(language.text("입력", "Enter")) { asksPassword = true }.font(.caption.weight(.semibold))
        case .replaced:
            Button(language.text("다시 연결", "Reconnect")) {
                Task {
                    await store.session(tripID: tripID)?.start()
                    await store.refresh(tripID: tripID)
                }
            }
            .font(.caption.weight(.semibold))
        case .ended:
            Button(language.text("확인", "OK")) { Task { await store.forget(tripID: tripID) } }.font(.caption.weight(.semibold))
        case .uploading, .offline: EmptyView()
        }
    }
}

/// 비밀번호가 바뀐 뒤 새 비밀번호를 받는다.
struct TripShareRekeySheet: View {
    let language: MapHomeLanguage
    let tripID: String
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(language.text("새 비밀번호", "New password"), text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("tripShareRekeyPassword")
                } footer: {
                    Text(message ?? language.text("방을 만든 사람이 비밀번호를 바꿨어요. 새 비밀번호를 물어봐 주세요.", "The room's creator changed the password. Ask them for the new one."))
                        .foregroundStyle(message == nil ? Color.secondary : Color.tpHoliday)
                }
                Section {
                    Button { submit() } label: {
                        HStack {
                            Text(language.text("확인", "OK"))
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || password.isEmpty)
                }
            }
            .navigationTitle(language.text("새 비밀번호", "New password"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(language.text("닫기", "Close")) { dismiss() } } }
        }
        .presentationDetents([.medium])
    }

    private func submit() {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                try await TripShareRoomWork.rekey(tripID: tripID, password: password)
                dismiss()
            } catch {
                message = TripShareRoomText.message(error, language)
            }
        }
    }
}
