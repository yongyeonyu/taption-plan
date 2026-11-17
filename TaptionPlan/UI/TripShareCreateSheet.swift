import SwiftUI
import TaptionPlanStore
import TaptionTripShare

// 묶음 A(TSH1114A26): 방 만들기와 기존 일정 올리기.
//
// 순서: 비밀번호 규칙(`SharePasswordPolicy`) → `ShareInvite.make()` → 키 유도(화면 밖) → 앱 등록 키 → `createRoom`
// → 연결을 「올리는 중」으로 적음 → 세션을 열어 내 카드·`meta`·일정(한 번에 `limits.batch`건)을 올림 → 「공유 중」.
// 좌표는 올리지 않는다: 장소는 핀 이름만 `TripShareMapping.plan(_:place:)`에 넘긴다.

/// 방 만들기와 올리기. 화면 없이도 돌게 따로 둔다(시험이 가짜 서버로 부른다).
@MainActor
enum TripShareCreation {
    /// 지금 올리고 있는 여행. 올리는 동안에는 화면을 떠나도 방을 닫지 않는다.
    private(set) static var uploading: Set<String> = []

    static let defaultLifeDays = 90
    static let lifeAfterTripDays = 30

    /// 이 여행에 「공유 만들기」를 낼 수 있는가. 참여한 여행은 다시 공유하지 못한다(규약 6.1).
    static func canCreate(store: TripShareStore = .shared, tripID: String) -> Bool {
        guard store.isAvailable, !isJoinedTrip(tripID) else { return false }
        guard let link = store.link(tripID: tripID) else { return true }
        return link.role == .owner && link.phase == .ended
    }

    static func isJoinedTrip(_ tripID: String) -> Bool {
        tripID.hasPrefix("s-") && ShareIdentifiers.isRoomID(String(tripID.dropFirst(2)))
    }

    /// 방의 기한: 여행 끝 + 30일(날짜가 없으면 지금 + 90일). 서버가 받는 범위(지금 + 1시간 ~ 400일) 안으로 맞춘다.
    static func expiry(trip: TravelTrip, now: Date) -> Int {
        let day: TimeInterval = 86_400
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let end = TravelTripDay.components(trip.endDay).flatMap(calendar.date(from:))
        let wanted = end.map { $0.addingTimeInterval(Double(lifeAfterTripDays + 1) * day) } ?? now.addingTimeInterval(Double(defaultLifeDays) * day)
        let clamped = min(max(wanted, now.addingTimeInterval(7 * day)), now.addingTimeInterval(399 * day))
        return Int(clamped.timeIntervalSince1970 * 1000)
    }

    /// 방을 만들고 연결을 「올리는 중」으로 적는다. 일정은 `upload`가 올린다(끊겨도 방과 초대는 남는다).
    static func create(
        store: TripShareStore = .shared, trip: TravelTrip, password: String, nickname: String,
        iterations: Int = ShareProtocolV1.pbkdf2Iterations
    ) async throws -> ShareInvite {
        guard let transport = store.environment.transport else { throw TripShareRoomError.unavailable }
        guard canCreate(store: store, tripID: trip.id) else { throw TripShareRoomError.joinedTrip }
        let password = try TripShareRoomWork.checked(password: password)
        let nickname = try TripShareRoomWork.cleaned(nickname: nickname)
        let invite = ShareInvite.make()
        let keys = try await TripShareRoomWork.keys(roomID: invite.roomID, linkSecret: invite.linkSecret, password: password, iterations: iterations)
        guard let appKey = await store.appKey() else { throw TripShareRoomError.notRegistered }
        let ownerKey = ShareIdentifiers.ownerKey()
        let entry = try await ShareRoomClient.createRoom(
            transport: transport, appKey: appKey,
            request: ShareCreateRequest(roomID: invite.roomID, proof: keys.proof, ownerKey: ownerKey, expiresAt: expiry(trip: trip, now: store.environment.session.now()))
        )
        // 끝난 옛 방의 연결이 남아 있으면 먼저 치운다.
        await store.forget(tripID: trip.id)
        TripShareRoomWork.savedNickname = nickname
        try store.register(
            TripShareLink(roomID: invite.roomID, tripID: trip.id, role: .owner, phase: .uploading),
            secrets: ShareRoomSecrets(root: keys.root, linkSecret: invite.linkSecret, token: entry.token, ownerKey: ownerKey, member: entry.member, epoch: entry.epoch)
        )
        return invite
    }

    /// 내 카드·여행 정보·일정을 방에 올린다. 이미 방에 있는 것은 건너뛰므로 끊긴 뒤 다시 불러도 된다.
    /// 다 올리면 연결을 「공유 중」으로 바꾼다.
    static func upload(model: AppModel, store: TripShareStore = .shared, tripID: String) async throws {
        guard var link = store.link(tripID: tripID), link.role == .owner, link.phase == .uploading, !uploading.contains(tripID) else { return }
        uploading.insert(tripID)
        defer { uploading.remove(tripID) }
        let session = try await TripShareRoomWork.liveSession(store: store, tripID: tripID)
        try await session.catchUp()
        var view = await session.view()
        if view.cards[view.me] == nil {
            try await session.publish(card: TripShareRoomWork.card(nickname: TripShareRoomWork.savedNickname, member: view.me))
        }
        if view.meta == nil, let trip = model.settings.travelTrips?.first(where: { $0.id == tripID }) {
            try await session.publish(meta: TripShareMapping.meta(trip))
        }
        let places = Dictionary(
            model.settings.travelPlanStops.filter { $0.tripID == tripID }.compactMap { stop in stop.itemID.map { ($0, stop) } },
            uniquingKeysWith: { first, _ in first }
        )
        // 코스의 곳(부모)을 세부 계획보다 먼저 올린다.
        let items = (model.settings.travelTripItems ?? []).filter { $0.tripID == tripID }
            .sorted { ($0.parentItemID == nil ? 0 : 1, $0.start, $0.itemID) < ($1.parentItemID == nil ? 0 : 1, $1.start, $1.itemID) }
        var conflicts = 0
        while true {
            view = await session.view()
            let present = Set(view.items.map(\.id)).union(link.uploaded)
            let batch = items.filter { !present.contains(TripShareMapping.roomItemID(tripID: tripID, itemID: $0.itemID)) }
                .prefix(max(1, min(view.limits.batch, 50)))
            guard !batch.isEmpty else { break }
            let edits = batch.map { item in
                let stop = places[item.itemID]
                let day = TravelTripDay.string(for: item.start, offsetSeconds: item.startOffsetSeconds)
                return ShareEdit.create(
                    id: TripShareMapping.roomItemID(tripID: tripID, itemID: item.itemID),
                    content: .plan(TripShareMapping.plan(item, place: stop?.title, order: stop?.order, by: view.me)),
                    group: store.groupName(tripID: tripID, day: day)
                )
            }
            if case .conflict = try await session.write(edits) {
                // 이미 올라가 있던 것과 부딪혔다. 세션이 최신본을 받았으니 다시 가려 올린다.
                conflicts += 1
                guard conflicts < 4 else { throw ShareError.interrupted }
                continue
            }
            link.uploaded += edits.map(\.id)
            try store.save(link)
        }
        // 공유 전 「다 같이」 지출은 들어온 동행 모두로 나눈다(대표 결정 2026-11-17).
        try await TripShareLedger.shareAllTogether(tripID: tripID, roomID: link.roomID, session: session, store: store)
        link.phase = .sharing
        link.uploaded = []
        try store.save(link)
        await store.refresh(tripID: tripID)
    }
}

/// 공유 만들기: 비밀번호·닉네임 → 방 만들기 → 올리는 중 → 초대 링크. 공유 판(`List`) 안에 구역으로 들어간다.
struct TripShareCreateSheet: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let trip: TravelTrip
    /// 만들기가 시작되면 true. 연결이 생겨도 초대 안내를 다 볼 때까지 공유 판이 이 화면을 붙들고 있게 한다.
    @Binding var started: Bool

    @State private var password = ""
    @State private var nickname = TripShareRoomWork.savedNickname
    @State private var busy = false
    @State private var message: String?
    @State private var inviteURL: URL?
    @State private var uploadFailed = false

    private var store: TripShareStore { .shared }

    var body: some View {
        if let inviteURL { created(inviteURL) } else { form }
    }

    @ViewBuilder
    private var form: some View {
        Section {
            TextField(language.text("비밀번호 (6자 이상)", "Password (6+ characters)"), text: $password)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("tripShareCreatePassword")
            TextField(language.text("내 닉네임", "My nickname"), text: $nickname)
                .accessibilityIdentifier("tripShareCreateNickname")
        } header: {
            Text(language.text("함께 쓰기", "Share with companions"))
        } footer: {
            Text(message ?? language.text(
                "초대 링크와 비밀번호를 둘 다 아는 사람만 들어올 수 있어요(10명까지). 비밀번호는 링크와 다른 방법으로 알려 주세요. 장소의 좌표는 올리지 않고 이름만 함께 봐요.",
                "Only people who know both the invite link and the password can join (up to 10). Send the password separately from the link. Place coordinates stay on your device; only names are shared."
            ))
            .foregroundStyle(message == nil ? Color.secondary : Color.tpHoliday)
        }
        Section {
            Button { submit() } label: {
                HStack {
                    Text(busy ? language.text("방을 만드는 중…", "Creating the room…") : language.text("공유 만들기", "Create share"))
                    if busy { Spacer(); ProgressView() }
                }
            }
            .disabled(busy || SharePasswordPolicy.issue(in: password) != nil || nickname.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("tripShareCreateSubmit")
        }
    }

    @ViewBuilder
    private func created(_ url: URL) -> some View {
        Section {
            ShareLink(item: url) { Label(language.text("초대 링크 보내기", "Send invite link"), systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier("tripShareCreateInvite")
            LabeledContent(language.text("비밀번호", "Password"), value: password)
        } header: {
            Text(language.text("방을 만들었어요", "Room created"))
        } footer: {
            Text(language.text(
                "비밀번호는 이 화면에서만 보여요. 링크와 다른 방법으로 따로 알려 주세요. 링크는 이 앱이 깔린 기기에서 열려요.",
                "The password is shown only here. Send it separately from the link. The link opens on devices with this app installed."
            ))
        }
        Section {
            if store.link(tripID: trip.id)?.phase == .uploading {
                if uploadFailed {
                    Button(language.text("일정 이어 올리기", "Resume uploading plans")) { upload() }
                } else {
                    HStack { Text(language.text("일정을 올리는 중…", "Uploading plans…")); Spacer(); ProgressView() }
                }
            }
            Button(language.text("완료", "Done")) { started = false }
                .accessibilityIdentifier("tripShareCreateDone")
        } footer: {
            if uploadFailed { Text(language.text("올리다 끊겼어요. 다시 연결되면 이어서 올려요.", "The upload was interrupted. It resumes when you're back online.")) }
        }
    }

    private func submit() {
        busy = true
        message = nil
        started = true
        Task {
            defer { busy = false }
            do {
                let invite = try await TripShareCreation.create(store: store, trip: trip, password: password, nickname: nickname)
                inviteURL = TripShareEnvironment.inviteURL(invite)
                upload()
            } catch {
                started = false
                message = TripShareRoomText.message(error, language)
            }
        }
    }

    private func upload() {
        uploadFailed = false
        Task {
            do { try await TripShareCreation.upload(model: model, store: store, tripID: trip.id) } catch { uploadFailed = true }
        }
    }
}
