import Foundation

/// 동행 위치 보내기·받기(LOC1116S01). 받은 위치는 메모리에만 두고 이력을 만들지 않는다.
public struct ShareLocationView: Sendable, Equatable {
    public var window: ShareLocWindow?
    /// 참여자 번호 순. 끈 사람은 없다.
    public var peers: [ShareReceivedLocation]
    /// 기기 시계로 본 지금의 서버 시각(「몇 분 전」 계산용).
    public var serverNow: Int
}

extension ShareRoomSession {
    public func locationView() -> ShareLocationView {
        ShareLocationView(window: locWindow, peers: peerLocations.values.sorted { $0.by < $1.by }, serverNow: serverNow())
    }

    /// 내 위치(또는 상태)를 방 키로 잠가 보낸다. 서버가 기간 창 밖이라 거절하면(`loc_closed`) 던진다.
    /// 지난 좌표를 쌓아 두지 않으므로 실패해도 다시 시도하지 않는다(다음 값으로).
    public func sendLocation(_ payload: ShareLocationPayload) async throws {
        guard !status.isFinal else { throw ShareError.readOnly(.notAllowed) }
        let cipher = try ShareLocationSealer.seal(payload, keys: keys, roomID: roomID, member: me, epoch: epoch)
        do {
            try await client.sendLocation(epoch: epoch, cipher: cipher, help: payload.s == .help)
        } catch let error as ShareError {
            if case .server(let failure) = error, failure.detail.error == "loc_closed" { locWindow = failure.detail.locWindow; emitLocations() }
            throw error
        }
    }

    /// 끄기: 서버에 둔 내 마지막 위치를 지운다.
    public func stopLocation() async throws {
        try await client.deleteLocation()
    }

    /// 주인만: 위치를 보낼 수 있는 기간을 정한다.
    public func setLocationWindow(_ window: ShareLocWindow) async throws {
        guard me == 1 else { throw ShareError.ownerKeyMissing }
        try await client.setLocationWindow(window)
        locWindow = window
        emitLocations()
    }

    /// 소켓이 없을 때 서버가 들고 있는 동행 위치를 HTTP로 받아 온다.
    public func refreshLocations() async {
        guard let list = try? await client.locationList() else { return }
        noteServerTime(list.now)
        locWindow = list.locWindow
        applyStored(list.locs)
    }

    // MARK: 받기

    func absorbLocations(_ state: ShareRoomState) {
        locWindow = state.locWindow
        applyStored(state.locs ?? [])
    }

    func receiveLocationWindow(_ event: ShareRoomEvent) {
        if event.epoch != epoch { peerLocations = [:] }
        guard locWindow != event.locWindow else { return emitLocationsIfChanged() }
        locWindow = event.locWindow
        emitLocations()
    }

    func receiveLocation(_ event: ShareWireLocation) {
        if event.all == true { peerLocations = [:]; return emitLocations() }
        guard let by = event.by, by != me else { return }
        if event.off == true {
            if peerLocations.removeValue(forKey: by) != nil { emitLocations() }
            return
        }
        guard let location = decode(event) else { return }
        if let old = peerLocations[by], old.receivedAt > location.receivedAt { return }
        peerLocations[by] = location
        emitLocations()
    }

    /// 서버가 둔 목록으로 통째로 맞춘다(목록에 없는 사람은 끈 것이거나 기한이 지난 것).
    private func applyStored(_ stored: [ShareWireLocation]) {
        var next: [Int: ShareReceivedLocation] = [:]
        for wire in stored where wire.by != me && wire.off != true {
            if let location = decode(wire) { next[location.by] = location }
        }
        guard next != peerLocations else { return emitLocations() }
        peerLocations = next
        emitLocations()
    }

    private func decode(_ wire: ShareWireLocation) -> ShareReceivedLocation? {
        guard let by = wire.by, let cipher = wire.cipher, let at = wire.at, let epoch = wire.epoch, epoch == self.epoch,
              let payload = ShareLocationSealer.open(cipher, keys: keys, roomID: roomID, member: by, epoch: epoch) else { return nil }
        // 숨김·끔은 좌표가 없으니 지도에는 올리지 않는다(화면이 「위치 숨김」만 보이려면 아래에서 따로 쓴다).
        return ShareReceivedLocation(by: by, payload: payload, receivedAt: at)
    }

    private func emitLocationsIfChanged() {}

    func emitLocations() { locationContinuation.yield() }
}
