import Foundation
import Observation
import TaptionPlanStore
import TaptionTripShare

/// 열린 주소로 들어온 초대를 잠깐 두는 받은함(TSH1114A26). 여행 화면이 뜨면 꺼내 입장 시트를 연다.
@MainActor
@Observable
final class TripShareInbox {
    static let shared = TripShareInbox()

    var pending: ShareInvite?

    /// 초대 주소면 받아 둔다. 진단 기록에는 호스트와 읽었는지만 남긴다(`#` 뒤의 방·비밀 값은 남기지 않는다).
    @discardableResult
    func receive(_ url: URL) -> Bool {
        let invite = TripShareEnvironment.invite(from: url.absoluteString)
        if let invite { pending = invite }
        TaptionPlanDiagnosticsLogger.shared.record(
            "deep_link_routed", fields: ["host": TripShareEnvironment.inviteHost, "route": "trip_share", "valid": String(invite != nil)]
        )
        return invite != nil
    }
}

/// 여행 화면이 띄울 공유 시트.
enum TripShareRoute: Identifiable, Equatable {
    /// 그 여행의 공유 판(공유 전이면 만들기, 공유 중이면 참여자·공지·정산·주인 동작).
    case panel(tripID: String)
    /// 초대로 참여. 열린 주소로 왔으면 초대가 들어 있고, 단추로 왔으면 nil(붙여넣기부터).
    case join(ShareInvite?)

    var id: String {
        switch self {
        case .panel(let tripID): "panel-" + tripID
        case .join(let invite): "join-" + (invite?.roomID ?? "")
        }
    }
}

/// 여행 공유의 단일 창구(TSH1114A26). 화면과 세 묶음(방·계획·가계부)은 방의 상태를 **여기서만** 읽고,
/// 세션(`ShareRoomSession`)도 여기서만 열고 닫는다. 내용의 정본은 로컬(SQLite)이고 이 창구는 동기 상태만 든다.
@MainActor
@Observable
final class TripShareStore {
    /// 앱 전체가 쓰는 창구. 시험은 가짜 환경으로 바꿔 넣고 끝나면 되돌린다.
    static var shared = TripShareStore(environment: .live)

    let environment: TripShareEnvironment
    /// 이 기기가 아는 방들(여행 번호 ↔ 방 번호·역할·상태).
    private(set) var links: [TripShareLink]
    /// 열린 방의 최신 화면 값(방 번호 → 불변 값). 세션이 변화를 알릴 때마다 바뀐다.
    private(set) var rooms: [String: ShareRoomView] = [:]
    /// 한 번 보일 안내 글(보기만·막은 편집). 화면이 띄우고 nil로 되돌린다.
    var notice: String?

    @ObservationIgnored private var sessions: [String: ShareRoomSession] = [:]
    @ObservationIgnored private var listeners: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var saving: [String: Task<Void, Never>] = [:]
    /// 열지 않은 방의 사람 수(곁 파일에서). 여행 카드의 「사람 N」에 쓴다.
    @ObservationIgnored private var storedMembers: [String: Int] = [:]
    /// 묶음 이름을 만드는 키(키체인에서 한 번 읽어 둔다). 키가 바뀌면 `saveSecrets`가 비운다.
    @ObservationIgnored private var keys: [String: ShareKeys] = [:]
    /// 방에서 본 닉네임(방 번호 → 참여자 번호 → 이름). 곁 파일에서 한 번 읽어 둔다.
    @ObservationIgnored private var seenNames: [String: [Int: String]] = [:]
    /// 방의 변화를 로컬 정본에 투영할 때 쓰는 앱 모델. 여행 화면이 뜰 때 붙는다.
    @ObservationIgnored private(set) weak var model: AppModel?

    init(environment: TripShareEnvironment) {
        self.environment = environment
        links = environment.isAvailable ? environment.sidecar.links() : []
        for link in links { storedMembers[link.roomID] = environment.sidecar.snapshot(roomID: link.roomID)?.members.count }
    }

    func attach(_ model: AppModel) { self.model = model }

    // MARK: 읽기

    /// 서버 주소가 없으면 공유 단추·시트를 모두 숨긴다.
    var isAvailable: Bool { environment.isAvailable }

    func link(tripID: String) -> TripShareLink? { links.first { $0.tripID == tripID } }
    func link(roomID: String) -> TripShareLink? { links.first { $0.roomID == roomID } }

    /// 지금 함께 쓰는 여행인가(올리는 중 포함). 끝난 방의 여행은 보통 여행이다.
    func isShared(_ tripID: String) -> Bool { link(tripID: tripID).map { $0.phase != .ended } ?? false }

    func view(tripID: String) -> ShareRoomView? { link(tripID: tripID).flatMap { rooms[$0.roomID] } }
    func session(tripID: String) -> ShareRoomSession? { link(tripID: tripID).flatMap { sessions[$0.roomID] } }

    /// 서버와 맞춰져 있어 고칠 수 있는가. 인터넷이 없거나 방을 열지 않았으면 보기만.
    func canEdit(_ tripID: String) -> Bool { view(tripID: tripID)?.canWrite ?? false }

    /// 방 사람 수(나 포함). 공유하지 않는 여행이면 nil.
    func memberCount(tripID: String) -> Int? {
        guard let link = link(tripID: tripID), link.phase != .ended else { return nil }
        return rooms[link.roomID]?.members.count ?? storedMembers[link.roomID]
    }

    /// 방 사람들의 이름표. 방을 열기 전이면 nil.
    func names(tripID: String) -> TripShareNames? {
        guard let link = link(tripID: tripID), let view = rooms[link.roomID] else { return nil }
        return names(view, roomID: link.roomID)
    }

    /// 그 방의 화면 값으로 만든 이름표. 나간 사람(카드가 지워진 사람)은 지난 이름으로 찾는다.
    func names(_ view: ShareRoomView, roomID: String) -> TripShareNames {
        TripShareNames(me: view.me, cards: view.cards, guests: view.meta?.guests ?? [], former: formerNames(roomID))
    }

    private func formerNames(_ roomID: String) -> [Int: String] {
        if let names = seenNames[roomID] { return names }
        let names = environment.sidecar.formerNames(roomID: roomID)
        seenNames[roomID] = names
        return names
    }

    /// 방에서 본 닉네임을 적어 둔다(바뀐 것이 있을 때만 곁 파일에 쓴다).
    private func remember(_ view: ShareRoomView, roomID: String) {
        var names = formerNames(roomID)
        for (member, card) in view.cards where !card.name.isEmpty { names[member] = card.name }
        guard names != seenNames[roomID] else { return }
        seenNames[roomID] = names
        try? environment.sidecar.saveFormerNames(names, roomID: roomID)
    }

    /// 로컬 일정 하나의 잠금 상태(그 일정의 잠금과 그날 묶음의 잠금). 기한은 기기 시계로 본다.
    func lockState(tripID: String, itemID: String, now: Date = .now) -> ShareLockState {
        guard let view = view(tripID: tripID) else { return .free }
        let roomItemID = TripShareMapping.roomItemID(tripID: tripID, itemID: itemID)
        var names = [ShareIdentifiers.itemLock(roomItemID)]
        if let group = view.items.first(where: { $0.id == roomItemID })?.group { names.append(ShareIdentifiers.groupLock(group)) }
        let millis = Int(now.timeIntervalSince1970 * 1000)
        let live = view.locks.filter { names.contains($0.name) && $0.until > millis }
        if let other = live.first(where: { $0.by != view.me }) { return .other(by: other.by, until: other.until) }
        if let mine = live.first { return .mine(until: mine.until) }
        return .free
    }

    /// 그날 일정들의 묶음 이름(날 묶음 잠금·`ShareEdit`의 `group`). 날짜가 서버에 보이지 않게 방의 키로 만든다.
    func groupName(tripID: String, day: String) -> String? {
        guard let link = link(tripID: tripID) else { return nil }
        if keys[link.roomID] == nil, let secrets = try? environment.secrets.secrets(roomID: link.roomID) {
            keys[link.roomID] = ShareKeys(roomID: link.roomID, root: secrets.root)
        }
        return keys[link.roomID]?.groupName(day: day)
    }

    /// 방 만들기에 쓸 앱 등록 키(등록을 먼저 보장한다). 못 받으면 nil.
    func appKey() async -> String? { await environment.appKey() }

    // MARK: 연결 만들기·고치기·지우기

    /// 방을 만들었거나 입장한 직후에 부른다: 비밀은 키체인에, 연결은 곁 파일에 적는다.
    func register(_ link: TripShareLink, secrets: ShareRoomSecrets) throws {
        try environment.secrets.save(secrets, roomID: link.roomID)
        try save(link)
    }

    /// 비밀번호를 바꿨거나 다시 증명한 뒤(키체인의 뿌리 키가 바뀜) 부른다.
    func saveSecrets(_ secrets: ShareRoomSecrets, roomID: String) throws {
        try environment.secrets.save(secrets, roomID: roomID)
        keys[roomID] = nil
    }

    /// 연결의 상태(올리는 중 → 공유 중, 올린 id들, 끝남)를 고쳐 적는다.
    func save(_ link: TripShareLink) throws {
        try environment.sidecar.save(link)
        if let index = links.firstIndex(where: { $0.roomID == link.roomID }) { links[index] = link } else { links.append(link) }
    }

    /// 이 기기에서 방을 잊는다: 세션을 닫고 비밀과 곁 파일, 그 여행의 위치 공유 켬을 지운다. **서버에는 알리지 않고, 로컬 여행은 남는다.**
    func forget(tripID: String) async {
        guard let link = link(tripID: tripID) else { return }
        await close(tripID: tripID)
        saving.removeValue(forKey: link.roomID)?.cancel()
        try? environment.secrets.remove(roomID: link.roomID)
        try? environment.sidecar.remove(roomID: link.roomID)
        links.removeAll { $0.roomID == link.roomID }
        storedMembers[link.roomID] = nil
        keys[link.roomID] = nil
        seenNames[link.roomID] = nil
        TripLiveLocationService.shared.forget(tripID: tripID)
    }

    // MARK: 세션

    /// 그 여행의 방을 연다(이미 열려 있으면 그것). 인터넷이 없어도 저장해 둔 사본으로 열려 보기만 된다.
    @discardableResult
    func open(tripID: String) async -> ShareRoomSession? {
        guard let link = link(tripID: tripID), link.phase != .ended, let transport = environment.transport else { return nil }
        if let session = sessions[link.roomID] { return session }
        guard let session = try? ShareRoomSession.open(
            roomID: link.roomID, transport: transport, secrets: environment.secrets, snapshots: environment.sidecar, environment: environment.session
        ) else { return nil }
        sessions[link.roomID] = session
        let view = await session.view()
        rooms[link.roomID] = view
        remember(view, roomID: link.roomID)
        listeners[link.roomID] = Task { [weak self] in
            for await event in session.events {
                guard let self, !Task.isCancelled else { return }
                await self.receive(event, from: session)
            }
        }
        await session.start()
        return session
    }

    func close(tripID: String) async {
        guard let link = link(tripID: tripID), let session = sessions.removeValue(forKey: link.roomID) else { return }
        listeners.removeValue(forKey: link.roomID)?.cancel()
        await session.stop()
        let snapshot = await session.snapshot()
        try? environment.sidecar.save(snapshot)
        storedMembers[link.roomID] = rooms.removeValue(forKey: link.roomID)?.members.count
    }

    /// 세션에 쓰기를 한 뒤(잠금·고치기·확인) 화면 값을 바로 다시 읽는다. 방송을 기다리지 않아도 된다.
    func refresh(tripID: String) async {
        guard let link = link(tripID: tripID), let session = sessions[link.roomID] else { return }
        rooms[link.roomID] = await session.view()
    }

    private func receive(_ event: ShareSessionEvent, from session: ShareRoomSession) async {
        let roomID = session.roomID
        guard sessions[roomID] === session, var link = link(roomID: roomID) else { return }
        let view = await session.view()
        rooms[roomID] = view
        remember(view, roomID: roomID)
        if case .status(.ended) = event, link.phase != .ended {
            // 내보내졌거나 방이 사라졌다. 로컬 사본은 보통 여행으로 남는다.
            link.phase = .ended
            try? save(link)
        }
        if case .locks = event {} else { scheduleSave(session) }
        guard let model else { return }
        // 묶음마다 자기 몫을 로컬 정본·알림에 반영한다. 올리는 중에는 「방이 이긴다」 맞춤을 돌리지 않는다(묶음이 `link.phase`를 본다).
        await TripSharePlanProjector.roomChanged(model: model, link: link, view: view, event: event)
        await TripShareLedger.roomChanged(model: model, link: link, view: view, event: event)
        await TripShareNoticeAlerts.roomChanged(model: model, link: link, view: view, event: event)
    }

    /// 변화가 잦아든 뒤(1초) 로컬 사본을 곁 파일에 적는다. 쓰기는 화면 밖에서 한다.
    private func scheduleSave(_ session: ShareRoomSession) {
        let roomID = session.roomID, sidecar = environment.sidecar
        saving[roomID]?.cancel()
        saving[roomID] = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let snapshot = await session.snapshot()
            await Self.write(snapshot, to: sidecar)
        }
    }

    private nonisolated static func write(_ snapshot: ShareRoomSnapshot, to sidecar: TripShareSidecar) async {
        try? sidecar.save(snapshot)
    }
}
