import Foundation

/// 방 하나의 동기 엔진. 로컬 사본을 들고, 따라잡고, 소켓 방송을 반영하고, 끊기면 다시 붙는다(9절).
/// 인터넷이 없으면 보기만 한다: 쓰기는 `ShareError.readOnly`로 실패한다.
/// 시작·고리·따라잡기는 이 파일에, 고치기·잠금·주인 동작은 `ShareRoomSession+Editing.swift`에 있다.
public actor ShareRoomSession {
    public nonisolated let roomID: String
    /// 변화 알림. 받으면 `view()`를 다시 읽는다. 한 곳에서만 듣는다.
    public nonisolated let events: AsyncStream<ShareSessionEvent>
    /// 동행 위치가 바뀌었음을 알린다(위치는 방 개정 번호와 별개라 `events`와 따로). 받으면 `locationView()`를 읽는다.
    public nonisolated let locationEvents: AsyncStream<Void>
    let locationContinuation: AsyncStream<Void>.Continuation

    let client: ShareRoomClient
    let environment: ShareSessionEnvironment
    private let continuation: AsyncStream<ShareSessionEvent>.Continuation

    var keys: ShareKeys
    var me: Int
    var epoch: Int
    var rev = 0
    var cursor = 0
    var closed = false
    var expiresAt = 0
    var members: [ShareMember] = []
    var locks: [String: ShareLock] = [:]
    var items: [String: ShareLocalItem] = [:]
    var unreadable: [String: ShareUnreadableItem] = [:]
    var limits = ShareLimits.v1
    var status = ShareSessionStatus.idle
    var held: Set<String> = []
    var rotating = false
    /// 다음 따라잡기는 처음부터 받아 로컬 사본을 통째로 맞춘다.
    var needsFullSync = true
    /// 동행 위치(메모리에만, 참여자 번호 → 푼 값). 저장하지 않는다.
    var peerLocations: [Int: ShareReceivedLocation] = [:]
    var locWindow: ShareLocWindow?

    private var tombstones: [String: Int] = [:]
    private var clockOffsetMs = 0
    private var generation = 0
    private var runTask: Task<Void, Never>?
    private var renewTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var runID = 0
    private var catchUpTask: Task<Void, any Error>?
    private var pendingRev = 0
    private var lastBye: ShareByeReason?

    /// - Parameters:
    ///   - member·epoch: 입장(또는 만들기) 응답의 값. 앱이 `ShareRoomSecrets`에 두었다가 넣는다.
    ///   - snapshot: 저장해 둔 로컬 사본. 방·참여자가 다르면 쓰지 않는다.
    public init(roomID: String, member: Int, epoch: Int, keys: ShareKeys, client: ShareRoomClient,
                snapshot: ShareRoomSnapshot? = nil, environment: ShareSessionEnvironment = ShareSessionEnvironment()) {
        self.roomID = roomID
        self.client = client
        self.environment = environment
        self.keys = keys
        me = member
        self.epoch = epoch
        (events, continuation) = AsyncStream.makeStream(of: ShareSessionEvent.self)
        (locationEvents, locationContinuation) = AsyncStream.makeStream(of: Void.self)
        guard let snapshot, snapshot.roomID == roomID, snapshot.me == member else { return }
        closed = snapshot.closed
        expiresAt = snapshot.expiresAt
        members = snapshot.members
        limits = snapshot.limits
        for stored in snapshot.items {
            if let item = Self.restore(stored) { items[item.id] = item }
        }
        for bad in snapshot.unreadable { unreadable[bad.id] = bad }
        if let ended = snapshot.ended { status = .ended(ended) }
        // 세대가 달라졌으면(그 사이 키 교체) 내용은 보여 주되 처음부터 다시 받는다.
        guard snapshot.epoch == epoch else { return }
        rev = snapshot.rev
        cursor = snapshot.cursor
        needsFullSync = false
    }

    /// 앱이 넣어 준 저장소들로 세션을 만든다. 이 방의 비밀이 없으면 nil.
    /// - Parameter transport: 기준 주소를 가진 전송(`URLSessionShareTransport(baseURL:)`).
    public static func open(roomID: String, transport: any ShareTransport, secrets: any ShareSecretStore, snapshots: (any ShareSnapshotStore)? = nil,
                            environment: ShareSessionEnvironment = ShareSessionEnvironment()) throws -> ShareRoomSession? {
        guard let secret = try secrets.secrets(roomID: roomID) else { return nil }
        let client = ShareRoomClient(transport: transport, roomID: roomID, token: secret.token, ownerKey: secret.ownerKey)
        return ShareRoomSession(roomID: roomID, member: secret.member, epoch: secret.epoch, keys: ShareKeys(roomID: roomID, root: secret.root),
                                client: client, snapshot: snapshots?.snapshot(roomID: roomID), environment: environment)
    }

    /// 지금의 로컬 사본을 저장소에 적는다(앱이 변화가 잦아든 때 부른다).
    public func persist(to store: any ShareSnapshotStore) throws {
        try store.save(snapshot())
    }

    // MARK: 읽기

    public func view() -> ShareRoomView {
        let now = serverNow()
        return ShareRoomView(
            generation: generation, status: status, me: me, isOwner: me == 1, epoch: epoch, rev: rev, closed: closed, expiresAt: expiresAt,
            members: members.sorted { $0.no < $1.no },
            locks: locks.values.filter { $0.until > now }.sorted { $0.name < $1.name },
            items: items.values.sorted { $0.id < $1.id },
            unreadable: unreadable.values.sorted { $0.id < $1.id },
            limits: limits
        )
    }

    public func item(_ id: String) -> ShareLocalItem? { items[id] }

    /// 잠금은 받은 `until`(서버 시각)이 기기 시계로 지나면 풀린 것으로 본다. 항목이 든 묶음의 잠금도 본다.
    public func lockState(item id: String) -> ShareLockState {
        let now = serverNow()
        var names = [ShareIdentifiers.itemLock(id)]
        if let group = items[id]?.group { names.append(ShareIdentifiers.groupLock(group)) }
        let live = names.compactMap { locks[$0] }.filter { $0.until > now }
        if let other = live.first(where: { $0.by != me }) { return .other(by: other.by, until: other.until) }
        if let mine = live.first { return .mine(until: mine.until) }
        return .free
    }

    /// 저장할 스냅샷. 키·토큰은 들어 있지 않다.
    public func snapshot() -> ShareRoomSnapshot {
        var ended: ShareEndReason?
        if case .ended(let reason) = status { ended = reason }
        return ShareRoomSnapshot(
            roomID: roomID, me: me, epoch: epoch, rev: rev, cursor: needsFullSync ? 0 : cursor, closed: closed, expiresAt: expiresAt,
            members: members,
            items: items.values.sorted { $0.id < $1.id }.map(Self.stored),
            unreadable: unreadable.values.sorted { $0.id < $1.id },
            limits: limits, ended: ended
        )
    }

    // MARK: 시작·끝

    /// 소켓을 붙이고 따라잡는다. 끊기면 지수 백오프로 다시 붙는다.
    /// 다른 연결에 밀려난 뒤(`replaced`)에도 이것으로 다시 붙는다.
    public func start() {
        guard runTask == nil, shouldRun || status == .replaced else { return }
        if status == .replaced { setStatus(.connecting) }
        runID += 1
        let id = runID
        runTask = Task { [weak self] in await self?.run(id) }
    }

    /// 화면을 닫을 때: 내 잠금을 풀고 연결을 닫는다. 로컬 사본은 남는다.
    public func stop() async {
        cancelRun()
        let mine = held.sorted()
        held = []
        if !mine.isEmpty, status == .live { _ = try? await client.lock(release: mine) }
        await client.disconnect()
        dropMyLocks()
        if shouldRun { setStatus(.idle) }
    }

    /// 지금 한 번 따라잡는다. 이미 하고 있으면 그것이 끝나기를 기다린다.
    public func catchUp() async throws {
        if let running = catchUpTask { return try await running.value }
        let task = Task { try await self.runCatchUp() }
        catchUpTask = task
        try await task.value
    }

    // MARK: 연결 고리

    var shouldRun: Bool {
        switch status {
        case .ended, .needsRekey, .replaced: false
        default: true
        }
    }

    private func run(_ id: Int) async {
        var attempt = 0
        while !Task.isCancelled, id == runID {
            if status != .live { setStatus(.connecting) }
            lastBye = nil
            var close: ShareSocketClose?
            var opened = false
            if let stream = try? await client.connect() {
                opened = true
                startPing()
                for await event in stream {
                    switch event {
                    case .message(let message):
                        if case .hello = message { attempt = 0 }
                        await handle(message)
                    case .closed(let reason):
                        close = reason
                    }
                }
            }
            guard !Task.isCancelled, id == runID else { return }
            // 소켓을 열지 못한 시도는 아무것도 닫지 않았다. HTTP로 잡은 잠금은 서버에 그대로다.
            if opened { socketDropped() }
            if endIfTold(close) { break }
            await probe()
            guard !Task.isCancelled, id == runID, shouldRun else { break }
            do { try await environment.sleep(.reconnect, ShareBackoff.delay(attempt: attempt, jitter: environment.jitter())) } catch { break }
            attempt += 1
        }
        if id == runID { runTask = nil }
    }

    /// 닫힘 코드(또는 그 앞의 `bye`)가 까닭을 알려 줬으면 그대로 처리하고 다시 붙지 않는다.
    private func endIfTold(_ close: ShareSocketClose?) -> Bool {
        let reason: ShareByeReason? = switch close {
        case .kicked: .kicked
        case .rekey: .rekey
        case .gone: .deleted
        case .replaced: .replaced
        default: lastBye
        }
        switch reason {
        case .kicked: setStatus(.ended(.kicked))
        case .left: setStatus(.ended(.left))
        case .deleted, .expired: setStatus(.ended(.gone))
        case .rekey: setStatus(.needsRekey)
        case .replaced: setStatus(.replaced)
        case nil: return false
        }
        return true
    }

    /// 까닭 모르게 끊겼을 때 HTTP로 서버를 본다: 나갔는지·방이 없는지·비밀번호가 바뀌었는지·인터넷이 없는지.
    /// 닿으면 소켓 없이도 `live`다(고치기는 HTTP로 간다).
    private func probe() async {
        do {
            let state = try await guarded { try await client.state() }
            absorb(state)
            absorbLocations(state)
            guard shouldRun else { return }
            setStatus(.live)
            if state.rev > rev || needsFullSync { try await catchUp() } else { emit(.caughtUp) }
        } catch {}
    }

    private func handle(_ message: ShareSocketMessage) async {
        guard !status.isFinal else { return }
        // HTTP 요청 하나가 끊겨 offline이 됐어도 소켓으로 소식이 오면 서버에 닿는 것이다.
        if status == .offline {
            if case .bye = message {} else { setStatus(.live) }
        }
        switch message {
        case .hello(let state):
            absorb(state)
            absorbLocations(state)
            guard shouldRun else { return await client.disconnect() }
            setStatus(.live)
            if state.rev > rev || needsFullSync { try? await catchUp() } else { emit(.caughtUp) }
        case .items(let event):
            applyAll(event.items)
            advance(to: event.rev, by: event.items.count)
        case .locks(let event):
            receive(event)
        case .ack(let event):
            receive(event)
        case .member(let event):
            receive(event)
        case .loc(let event):
            receiveLocation(event)
        case .room(let event):
            receiveLocationWindow(event)
            receive(event)
            if !shouldRun { await client.disconnect() }
        case .bye(let reason):
            lastBye = reason
        case .response, .pong, .unknown:
            break
        }
    }

    private func socketDropped() {
        pingTask?.cancel()
        pingTask = nil
        held = []
        dropMyLocks()
    }

    /// 마지막 연결이 끊기면 서버가 내 잠금을 모두 푼다.
    private func dropMyLocks() {
        let mine = locks.filter { $0.value.by == me }.map(\.key)
        guard !mine.isEmpty else { return }
        for name in mine { locks[name] = nil }
        emit(.locks)
    }

    private func cancelRun() {
        runID += 1
        runTask?.cancel()
        runTask = nil
        renewTask?.cancel()
        renewTask = nil
        pingTask?.cancel()
        pingTask = nil
    }

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [environment, client] in
            while !Task.isCancelled {
                do { try await environment.sleep(.ping, environment.pingInterval) } catch { return }
                await client.ping()
            }
        }
    }

    // MARK: 방송 반영

    private func receive(_ event: ShareLocksEvent) {
        noteServerTime(event.now)
        for lock in event.set { locks[lock.name] = lock }
        for name in event.clear { locks[name] = nil }
        if event.by == me { held.subtract(event.clear) }
        emit(.locks)
    }

    private func receive(_ event: ShareAckEvent) {
        if var item = items[event.id], item.seq < event.seq {
            item.acks[event.by] = event.at
            item.seq = event.seq
            items[event.id] = item
            emit(.items(changed: [event.id], removed: []))
        }
        advance(to: event.rev, by: 1)
    }

    private func receive(_ event: ShareMemberEvent) {
        noteServerTime(event.now)
        switch event.event {
        case .join:
            guard !members.contains(where: { $0.no == event.no }) else { return }
            members.append(ShareMember(no: event.no, joinedAt: event.now, online: false, stale: nil))
        case .leave, .kick:
            members.removeAll { $0.no == event.no }
        case .online, .offline:
            guard let index = members.firstIndex(where: { $0.no == event.no }) else { return }
            members[index].online = event.event == .online
        }
        emit(.members)
    }

    private func receive(_ event: ShareRoomEvent) {
        noteServerTime(event.now)
        if closed != event.closed || expiresAt != event.expiresAt {
            closed = event.closed
            expiresAt = event.expiresAt
            emit(.room)
        }
        // 내가 지금 바꾸는 중이 아닌데 세대가 올랐으면(주인의 다른 기기 포함) 새 비밀번호가 필요하다.
        if event.epoch != epoch, !rotating { setStatus(.needsRekey) }
    }

    func absorb(_ state: ShareRoomState) {
        noteServerTime(state.now)
        me = state.you
        limits = state.limits
        if members != state.members {
            members = state.members
            emit(.members)
        }
        let table = Dictionary(state.locks.map { ($0.name, $0) }, uniquingKeysWith: { $1 })
        if locks != table {
            locks = table
            emit(.locks)
        }
        if closed != state.closed || expiresAt != state.expiresAt {
            closed = state.closed
            expiresAt = state.expiresAt
            emit(.room)
        }
        if state.epoch != epoch, !rotating { setStatus(.needsRekey) }
    }

    // MARK: 따라잡기

    /// 방 `rev`를 올리는 소식(항목 쓰기·공지 확인)을 받았을 때: 순번이 이어지면 나아가고, 비면 따라잡는다.
    func advance(to newRev: Int, by count: Int) {
        if catchUpTask != nil {
            pendingRev = max(pendingRev, newRev)
            return
        }
        guard newRev > rev else { return }
        if rev + count == newRev, !needsFullSync {
            rev = newRev
            cursor = newRev
        } else {
            scheduleCatchUp()
        }
    }

    func scheduleCatchUp() {
        Task { try? await self.catchUp() }
    }

    private func runCatchUp() async throws {
        defer { catchUpTask = nil }
        repeat {
            pendingRev = 0
            let full = needsFullSync
            if full {
                cursor = 0
                tombstones = [:]
            }
            var seen: Set<String> = []
            var more = true
            while more {
                let page = try await guarded { try await client.changes(since: cursor) }
                guard page.epoch == epoch else {
                    setStatus(.needsRekey)
                    throw ShareError.readOnly(.needsRekey)
                }
                for item in page.items { seen.insert(item.id) }
                applyAll(page.items)
                cursor = page.next
                more = page.more
                if !more { rev = page.next }
                if closed != page.closed {
                    closed = page.closed
                    emit(.room)
                }
            }
            if full {
                prune(keeping: seen)
                needsFullSync = false
            }
        } while pendingRev > rev
        emit(.caughtUp)
    }

    /// 처음부터 받았는데 오지 않은 항목은 서버에 없는 것이다(처음 받기에는 묘비가 오지 않는다).
    private func prune(keeping seen: Set<String>) {
        let gone = items.values.filter { !seen.contains($0.id) && $0.seq <= rev }.map(\.id)
        for id in gone { items[id] = nil }
        for bad in unreadable.values where !seen.contains(bad.id) { unreadable[bad.id] = nil }
        if !gone.isEmpty { emit(.items(changed: [], removed: gone.sorted())) }
    }

    private enum Change { case changed, removed }

    func applyAll(_ wire: [ShareWireItem]) {
        var changed: [String] = []
        var removed: [String] = []
        for item in wire {
            switch apply(item) {
            case .changed: changed.append(item.id)
            case .removed: removed.append(item.id)
            case nil: break
            }
        }
        if !changed.isEmpty || !removed.isEmpty { emit(.items(changed: changed, removed: removed)) }
    }

    /// 같은 id는 `seq`가 더 큰 쪽이 이긴다. 풀리지 않는 항목은 버린다.
    private func apply(_ item: ShareWireItem) -> Change? {
        if let old = items[item.id], old.seq >= item.seq { return nil }
        if let dead = tombstones[item.id], dead >= item.seq { return nil }
        if item.isTombstone {
            tombstones[item.id] = item.seq
            unreadable[item.id] = nil
            return items.removeValue(forKey: item.id) == nil ? nil : .removed
        }
        guard let local = open(item) else {
            unreadable[item.id] = ShareUnreadableItem(id: item.id, kind: item.kind, rev: item.rev, cipher: item.cipher)
            return items.removeValue(forKey: item.id) == nil ? nil : .removed
        }
        unreadable[item.id] = nil
        items[item.id] = local
        return .changed
    }

    private func open(_ item: ShareWireItem) -> ShareLocalItem? {
        guard item.epoch == epoch, let cipher = item.cipher,
              let plain = ShareCipher.open(cipher, key: keys.encKey, context: context(item.id, item.kind, epoch: epoch)),
              let content = try? ShareContent.decode(kind: item.kind, json: plain) else { return nil }
        var acks: [Int: Int] = [:]
        for (member, at) in item.acks ?? [:] { if let no = Int(member) { acks[no] = at } }
        let json = String(decoding: plain, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return ShareLocalItem(id: item.id, kind: item.kind, rev: item.rev, seq: item.seq, epoch: epoch, group: item.group,
                              updatedAt: item.updatedAt, by: item.by, createdBy: item.createdBy, acks: acks, json: json, content: content)
    }

    func context(_ id: String, _ kind: String, epoch: Int) -> ShareItemContext {
        ShareItemContext(roomID: roomID, itemID: id, kind: kind, epoch: epoch)
    }

    /// 내가 쓴 것을 서버가 받아 준 뒤 로컬 사본에 넣는다(소켓으로 쓴 것은 방송으로 돌아오지 않는다).
    func store(_ item: ShareLocalItem) {
        if let old = items[item.id], old.seq > item.seq { return }
        items[item.id] = item
        unreadable[item.id] = nil
    }

    func forget(_ id: String, seq: Int) {
        tombstones[id] = seq
        items[id] = nil
        unreadable[id] = nil
    }

    // MARK: 상태·오류

    func requireLive() throws {
        switch status {
        case .live: return
        case .idle, .connecting: throw ShareError.readOnly(.notStarted)
        case .offline: throw ShareError.readOnly(.offline)
        case .needsRekey: throw ShareError.readOnly(.needsRekey)
        case .replaced: throw ShareError.readOnly(.replaced)
        case .ended: throw ShareError.readOnly(.ended)
        }
    }

    /// 요청을 하고, 실패가 방의 상태를 알려 주는 것이면(나감·없음·비밀번호 바뀜·인터넷 없음) 상태에 반영한 뒤 그대로 던진다.
    func guarded<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as ShareError {
            absorb(error)
            throw error
        }
    }

    private func absorb(_ error: ShareError) {
        switch error {
        case .offline, .transport:
            if shouldRun { setStatus(.offline) }
        case .server(let failure):
            if let now = failure.detail.now { noteServerTime(now) }
            switch failure.code {
            case .removed: setStatus(.ended(failure.detail.reason == "left" ? .left : .kicked))
            case .notFound where failure.status == 404: setStatus(.ended(.gone))
            case .rekeyRequired: setStatus(.needsRekey)
            case .settlementClosed:
                if !closed {
                    closed = true
                    emit(.room)
                }
            case .locked:
                for lock in failure.detail.locks ?? [] { locks[lock.name] = lock }
                emit(.locks)
            default: break
            }
        default:
            break
        }
    }

    func setStatus(_ new: ShareSessionStatus) {
        guard status != new, !status.isFinal else { return }
        status = new
        if !shouldRun {
            cancelRun()
            held = []
        }
        if new.isFinal {
            let client = client
            Task { await client.disconnect() }
        }
        emit(.status(new))
    }

    func emit(_ event: ShareSessionEvent) {
        generation += 1
        continuation.yield(event)
    }

    /// 기기 시계로 본 지금의 서버 시각(밀리초).
    func serverNow() -> Int { deviceNow() + clockOffsetMs }

    func noteServerTime(_ now: Int) { clockOffsetMs = now - deviceNow() }

    private func deviceNow() -> Int { Int((environment.now().timeIntervalSince1970 * 1000).rounded()) }

    // MARK: 잠금 연장

    /// 잡고 있는 잠금을 60초마다 다시 잡는다(임대는 2분). 잡은 것이 없어질 때만 멈춘다.
    /// 차례가 왔을 때 `live`가 아니면(잠깐 끊김) 그 차례만 건너뛴다.
    func startRenewal() {
        guard renewTask == nil else { return }
        renewTask = Task { [weak self, environment] in
            while !Task.isCancelled {
                do { try await environment.sleep(.lockRenewal, environment.lockRenewInterval) } catch { return }
                guard let self, await self.renewLocks() else { return }
            }
        }
    }

    private func renewLocks() async -> Bool {
        guard !held.isEmpty, shouldRun else {
            renewTask = nil
            return false
        }
        guard status == .live else { return true }
        do {
            try await acquire(held.sorted())
        } catch ShareError.server(let failure) where failure.code == .locked {
            held = [] // 임대가 끊긴 사이 남이 잡았다. 화면은 `locks` 알림으로 안다.
            dropMyLocks()
        } catch {}
        return true
    }

    func acquire(_ names: [String]) async throws {
        let result = try await guarded { try await client.lock(acquire: names) }
        noteServerTime(result.now)
        for lock in result.locks { locks[lock.name] = lock }
        held.formUnion(names)
        startRenewal()
        emit(.locks)
    }

    // MARK: 스냅샷 변환

    private static func stored(_ item: ShareLocalItem) -> ShareRoomSnapshot.Item {
        var acks: [String: Int] = [:]
        for (member, at) in item.acks { acks[String(member)] = at }
        return ShareRoomSnapshot.Item(id: item.id, kind: item.kind, rev: item.rev, seq: item.seq, epoch: item.epoch, group: item.group,
                                      updatedAt: item.updatedAt, by: item.by, createdBy: item.createdBy, acks: acks, json: item.json)
    }

    private static func restore(_ stored: ShareRoomSnapshot.Item) -> ShareLocalItem? {
        guard let content = try? ShareContent.decode(kind: stored.kind, json: Data(stored.json.utf8)) else { return nil }
        var acks: [Int: Int] = [:]
        for (member, at) in stored.acks { if let no = Int(member) { acks[no] = at } }
        return ShareLocalItem(id: stored.id, kind: stored.kind, rev: stored.rev, seq: stored.seq, epoch: stored.epoch, group: stored.group,
                              updatedAt: stored.updatedAt, by: stored.by, createdBy: stored.createdBy, acks: acks, json: stored.json, content: content)
    }
}
