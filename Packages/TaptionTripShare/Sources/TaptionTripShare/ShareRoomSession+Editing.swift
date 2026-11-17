import Foundation

// 고치기·잠금·공지 확인·비밀번호 바꾸기·주인 동작. 모두 서버가 받아 준 뒤에만 로컬 사본을 바꾼다.
extension ShareRoomSession {
    // MARK: 쓰기

    /// 한 번에 보낸 것은 전부 되거나 전부 안 된다. `plan`·`expense-shared`를 고치거나 지우려면 먼저 `lock`을 잡는다.
    /// 충돌이면 로컬 사본이 서버의 최신본으로 바뀌고 `.conflict`가 돌아온다.
    @discardableResult
    public func write(_ edits: [ShareEdit]) async throws -> ShareEditOutcome {
        try requireLive()
        guard !edits.isEmpty else { return .done }
        let drafts = try edits.map(draft)
        let writes = drafts.map(\.write)
        let outcome = try await guarded { try await client.write(epoch: epoch, writes: writes) }
        switch outcome {
        case .done(let result):
            keep(drafts, receipts: result.items)
            advance(to: result.rev, by: drafts.count)
            return .done
        case .conflict(let conflicts, _):
            let missing = conflicts.filter { $0.current == nil }.map(\.id)
            for id in missing { forget(id, seq: 0) }
            if !missing.isEmpty { emit(.items(changed: [], removed: missing)) }
            applyAll(conflicts.compactMap(\.current))
            scheduleCatchUp()
            return .conflict(conflicts.map { ShareEditConflict(id: $0.id, current: items[$0.id]) })
        }
    }

    /// 내 참여자 카드(닉네임·색). 입장 뒤 한 번 올리고, 바꿀 때 다시 부른다.
    @discardableResult
    public func publish(card: ShareMemberCard) async throws -> ShareEditOutcome {
        try await upsert(id: ShareIdentifiers.memberCardID(me), content: .member(card))
    }

    /// 여행 정보(주인만).
    @discardableResult
    public func publish(meta: ShareTripMeta) async throws -> ShareEditOutcome {
        try await upsert(id: ShareIdentifiers.metaID, content: .meta(meta))
    }

    private func upsert(id: String, content: ShareContent) async throws -> ShareEditOutcome {
        try await write([items[id] == nil ? .create(id: id, content: content, group: nil) : .update(id: id, content: content, group: .keep)])
    }

    private struct Draft {
        var write: ShareWrite
        /// 지우기면 nil.
        var item: ShareLocalItem?
    }

    private func draft(_ edit: ShareEdit) throws -> Draft {
        switch edit {
        case .create(let id, let content, let group):
            try permit(kind: content.kind, id: id, old: nil, deleting: false)
            let (cipher, json) = try seal(content, id: id)
            let item = ShareLocalItem(id: id, kind: content.kind, rev: 0, seq: 0, epoch: epoch, group: group, updatedAt: 0, by: me, createdBy: me,
                                      acks: [:], json: json, content: content)
            return Draft(write: .put(id: id, kind: content.kind, baseRev: 0, cipher: cipher, group: group.map(ShareGroupChange.set) ?? .keep), item: item)
        case .update(let id, let content, let group):
            guard var item = items[id] else { throw ShareError.unknownItem }
            guard item.kind == content.kind else { throw ShareError.readOnly(.notAllowed) } // 종류는 바꾸지 못한다(지우고 새로 만든다).
            guard !item.isReadOnly else { throw ShareError.readOnly(.newerVersion) }
            try permit(kind: item.kind, id: id, old: item, deleting: false)
            let (cipher, json) = try seal(content, id: id)
            let baseRev = item.rev
            switch group {
            case .keep: break
            case .clear: item.group = nil
            case .set(let name): item.group = name
            }
            item.json = json
            item.content = content
            if item.kind == ShareKind.notice.rawValue { item.acks = [:] } // 공지를 고치면 확인이 비워진다.
            return Draft(write: .put(id: id, kind: item.kind, baseRev: baseRev, cipher: cipher, group: group), item: item)
        case .delete(let id):
            guard let item = items[id] else { throw ShareError.unknownItem }
            try permit(kind: item.kind, id: id, old: item, deleting: true)
            return Draft(write: .remove(id: id, baseRev: item.rev), item: nil)
        }
    }

    /// 서버의 권한 표(10절)를 미리 본다. 서버도 같은 것을 강제한다.
    private func permit(kind: String, id: String, old: ShareLocalItem?, deleting: Bool) throws {
        guard let kind = ShareKind(rawValue: kind) else { throw ShareError.readOnly(.newerVersion) }
        let mine = old == nil || old?.createdBy == me
        let allowed: Bool
        switch kind {
        case .plan: allowed = true
        case .expenseShared:
            guard !closed else { throw ShareError.readOnly(.settlementClosed) }
            allowed = true
        case .expenseOwn: allowed = mine
        case .notice: allowed = mine || (deleting && me == 1)
        case .member: allowed = id == ShareIdentifiers.memberCardID(me) && !deleting
        case .meta: allowed = me == 1
        case .meet: allowed = id == ShareMeetContent.itemID && !deleting // 누구나, 지우지는 못한다(서버가 기간 창도 본다).
        }
        guard allowed, (kind == .member) == id.hasPrefix(ShareIdentifiers.memberPrefix) else { throw ShareError.readOnly(.notAllowed) }
    }

    /// 평문 JSON을 64바이트 배수로 맞춰 잠근다. 맞추면 한도를 넘는 경우에만 그대로 잠근다.
    private func seal(_ content: ShareContent, id: String) throws -> (cipher: String, json: String) {
        let json = try content.json()
        let padded = ShareCipher.padded(json)
        let fits = { (data: Data) in ShareCipher.sealedBytes(plaintextBytes: data.count) <= self.limits.itemBytes }
        guard fits(json) else { throw ShareError.itemTooLarge }
        let cipher = try ShareCipher.seal(fits(padded) ? padded : json, key: keys.encKey, context: context(id, content.kind, epoch: epoch))
        return (cipher, String(decoding: json, as: UTF8.self))
    }

    private func keep(_ drafts: [Draft], receipts: [ShareWriteReceipt]) {
        var changed: [String] = []
        var removed: [String] = []
        for (draft, receipt) in zip(drafts, receipts) {
            guard var item = draft.item else {
                forget(receipt.id, seq: receipt.seq)
                removed.append(receipt.id)
                continue
            }
            item.rev = receipt.rev
            item.seq = receipt.seq
            item.updatedAt = receipt.updatedAt
            item.by = me
            store(item)
            changed.append(item.id)
        }
        emit(.items(changed: changed, removed: removed))
    }

    // MARK: 잠금

    /// 고치기 시작할 때 잡는다. 잡고 있는 동안 60초마다 스스로 연장한다.
    /// 남이 잡고 있으면 `ShareError.server`(`locked`, `detail.locks`에 누가)이고 아무것도 잡히지 않는다.
    /// - Parameter groups: `ShareKeys.groupName(day:)`로 만든 묶음 이름(순서 바꾸기처럼 한 날을 함께 쓸 때).
    public func lock(items ids: [String] = [], groups: [String] = []) async throws {
        try requireLive()
        let names = Self.lockNames(ids, groups)
        guard !names.isEmpty else { return }
        try await acquire(names)
    }

    /// 잡고 있는 잠금을 지금 연장한다(평소에는 60초마다 스스로 한다).
    public func extendLocks() async throws {
        try requireLive()
        guard !held.isEmpty else { return }
        try await acquire(held.sorted())
    }

    /// 고치기를 마쳤을 때(쓰기 뒤) 푼다.
    public func unlock(items ids: [String] = [], groups: [String] = []) async throws {
        let names = Self.lockNames(ids, groups)
        guard !names.isEmpty else { return }
        held.subtract(names)
        let result = try await guarded { try await client.lock(release: names) }
        for name in result.released { locks[name] = nil }
        emit(.locks)
    }

    private static func lockNames(_ ids: [String], _ groups: [String]) -> [String] {
        ids.map(ShareIdentifiers.itemLock) + groups.map(ShareIdentifiers.groupLock)
    }

    // MARK: 공지

    /// 공지를 확인했다고 알린다. 여러 번 해도 처음 시각 그대로다.
    public func acknowledge(noticeID: String) async throws {
        try requireLive()
        let result = try await guarded { try await client.acknowledge(noticeID: noticeID) }
        if var item = items[noticeID], item.seq <= result.seq {
            var acks: [Int: Int] = [:]
            for (member, at) in result.acks { if let no = Int(member) { acks[no] = at } }
            item.acks = acks
            item.seq = result.seq
            items[noticeID] = item
            emit(.items(changed: [noticeID], removed: []))
        }
        advance(to: result.rev, by: 1)
    }

    // MARK: 비밀번호가 바뀐 뒤

    /// 참여자: 새 비밀번호로 만든 키를 넣는다. 맞으면 처음부터 다시 받는다. 틀리면 `wrongPassword`(`remaining`).
    /// 돌아온 세대와 새 뿌리 키를 앱이 키체인에 다시 적는다.
    @discardableResult
    public func rekey(with newKeys: ShareKeys) async throws -> ShareRekeyResult {
        guard !status.isFinal else { throw ShareError.readOnly(.ended) }
        let result = try await guarded { try await client.rekey(proof: newKeys.proof) }
        adopt(newKeys, epoch: result.epoch)
        setStatus(.connecting)
        start()
        return result
    }

    private func adopt(_ newKeys: ShareKeys, epoch newEpoch: Int) {
        keys = newKeys
        epoch = newEpoch
        needsFullSync = true
        held = []
        if !locks.isEmpty {
            locks = [:] // 키 교체는 모든 잠금을 푼다.
            emit(.locks)
        }
        emit(.room)
    }

    // MARK: 주인만

    /// 비밀번호 바꾸기 = 키 교체(15절). 끝까지 따라잡고 살아 있는 모든 항목을 새 키·새 세대로 다시 잠가 한 번에 올린다.
    /// 그 사이 누가 썼으면(409) 처음부터 다시 한다(세 번까지).
    /// - Parameter discardingUnreadable: 풀지 못한 항목이 있을 때 false면 `unreadableItems`로 멈추고,
    ///   true면 받은 암호문 그대로 올려 넘어간다(그 항목은 새 키로도 풀리지 않는다).
    /// 응답을 못 받고 끊겼으면(`offline`·`transport`) 됐는지 모른다. 새 키를 버리지 말고 `confirmRotation`으로 확인한다.
    @discardableResult
    public func rotate(to newKeys: ShareKeys, discardingUnreadable: Bool = false) async throws -> ShareRekeyResult {
        try requireLive()
        guard me == 1 else { throw ShareError.readOnly(.notAllowed) }
        rotating = true
        defer { rotating = false }
        var failure = ShareError.interrupted
        for _ in 0..<3 {
            needsFullSync = true // 빠진 것이 없도록 처음부터 받는다.
            try await catchUp()
            guard discardingUnreadable || unreadable.isEmpty else { throw ShareError.unreadableItems(unreadable.keys.sorted()) }
            let entries = try resealed(with: newKeys)
            let result: ShareRekeyResult
            do {
                result = try await guarded { try await client.rotate(rev: rev, proof: newKeys.proof, items: entries) }
            } catch let error as ShareError where error.serverCode == .conflict {
                failure = error
                continue
            }
            adopt(newKeys, epoch: result.epoch)
            await resumeWithNewKeys()
            return result
        }
        throw failure
    }

    /// 서버가 새 키를 받아 준 뒤: 그것으로 키 교체는 끝났다. 따라잡기는 한 번 해 보고, 안 되면 연결 고리에 맡긴다
    /// (`needsFullSync`가 남아 다음 `hello`·상태 확인이 처음부터 받는다). 앱은 돌려받은 세대와 새 뿌리 키를 적는다.
    /// 그 사이 4001이나 다른 세대의 `room`으로 고리가 멈췄으면(`needsRekey`) 다시 붙인다.
    private func resumeWithNewKeys() async {
        if status == .needsRekey { setStatus(.connecting) }
        start()
        try? await catchUp()
    }

    /// `rotate`가 응답 없이 끊긴 뒤: 서버의 세대가 올랐으면 새 키로 넘어가고 true.
    public func confirmRotation(with newKeys: ShareKeys) async throws -> Bool {
        rotating = true
        defer { rotating = false }
        let state = try await guarded { try await client.state() }
        guard state.epoch > epoch else { return false }
        adopt(newKeys, epoch: state.epoch)
        absorb(state)
        setStatus(.live)
        await resumeWithNewKeys()
        return true
    }

    private func resealed(with newKeys: ShareKeys) throws -> [ShareRotateItem] {
        var entries = try items.values.sorted { $0.id < $1.id }.map { item in
            let plain = Data(item.json.utf8)
            let padded = ShareCipher.padded(plain)
            let body = ShareCipher.sealedBytes(plaintextBytes: padded.count) <= limits.itemBytes ? padded : plain
            return ShareRotateItem(id: item.id, cipher: try ShareCipher.seal(body, key: newKeys.encKey, context: context(item.id, item.kind, epoch: epoch + 1)))
        }
        for bad in unreadable.values.sorted(by: { $0.id < $1.id }) {
            guard let cipher = bad.cipher else { throw ShareError.unreadableItems([bad.id]) }
            entries.append(ShareRotateItem(id: bad.id, cipher: cipher))
        }
        return entries
    }

    /// 내보내기. 내보낸 사람은 링크와 비밀번호를 알므로, `rekeyRecommended`면 비밀번호 바꾸기를 권한다.
    @discardableResult
    public func kick(member: Int) async throws -> ShareKickResult {
        try requireLive()
        return try await guarded { try await client.kick(member: member) }
    }

    /// 정산 마감(true)·다시 열기(false). 마감하면 서버가 공유 지출 쓰기를 거절한다.
    public func setSettlementClosed(_ value: Bool) async throws {
        try requireLive()
        let result = try await guarded { try await client.setClosed(value) }
        guard closed != result else { return }
        closed = result
        emit(.room)
    }

    public func setExpiry(_ value: Int) async throws {
        try requireLive()
        let result = try await guarded { try await client.setExpiry(value) }
        guard expiresAt != result else { return }
        expiresAt = result
        emit(.room)
    }

    /// 방을 통째로 지운다. 되돌릴 수 없다. 로컬 사본은 남는다.
    public func deleteRoom() async throws {
        try requireLive()
        try await guarded { try await client.deleteRoom() }
        setStatus(.ended(.gone))
    }

    // MARK: 나가기

    /// 주인은 나가지 못한다(`ownerCannotLeave`). 로컬 사본은 남는다.
    public func leave() async throws {
        try await guarded { try await client.leave() }
        setStatus(.ended(.left))
    }
}
