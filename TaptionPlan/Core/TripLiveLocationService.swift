import CoreLocation
import Foundation
import Observation
import TaptionTripShare
import UIKit

/// 지도에 올릴 동행 한 명(또는 모이는 곳).
struct TravelCompanionMark: Equatable, Identifiable {
    enum Kind: Equatable { case person, meet }

    var id: String
    var kind: Kind
    var initial: String
    var colorHex: String
    var longitude: Double
    var latitude: Double
    var caption: String
    var opacity: Double
    var isHelp: Bool
    /// 정확도 반경(m). 모이는 곳은 0.
    var accuracy: Double
}

/// 수집기가 받은 위치를 이 서비스로 한 줄에 넘긴다(`AppleSensorCollector+Updates.swift`). 새 위치 수집은 하지 않는다.
enum TripLiveLocationFeed {
    nonisolated static func offer(_ location: CLLocation) {
        Task { @MainActor in TripLiveLocationService.shared.offer(location) }
    }
}

/// 여행 중 동행 위치 공유(LOC1116S01): 본인이 켠 여행에서만, 방이 정한 기간 안에서만, 방 키로 암호화해 보낸다.
/// 받은 위치는 메모리에만 둔다. 설계: `docs/TRIP_LIVE_LOCATION_PLAN.md`. 켜는 것을 막는 스위치는 `isAvailable` 하나다.
@MainActor
@Observable
final class TripLiveLocationService {
    /// 앱 전체가 쓰는 서비스. 시험은 따로 만든 것으로 바꿔 넣고 끝나면 되돌린다.
    static var shared = TripLiveLocationService()
    /// 법 검토(위치정보법)가 끝나기 전에 끄려면 false로 한다.
    static let isAvailable = true

    private(set) var consents: [String: TripLiveLocationConsent]
    /// 여행 번호 → 받은 동행 위치와 기간 창.
    private(set) var views: [String: ShareLocationView] = [:]
    /// 「몇 분 전」을 새로 그리게 하는 분 단위 값.
    private(set) var minuteTick = 0
    /// 한 번 보일 안내(기간이 끝나 꺼짐 등). 화면이 띄우고 nil로 되돌린다.
    var notice: String?
    private(set) var helpTrips: Set<String> = []

    @ObservationIgnored private var capturedAt: [String: Date] = [:]
    @ObservationIgnored private var lastSent: [String: TripLiveLocationPolicy.Fix] = [:]
    @ObservationIgnored private var latest: TripLiveLocationPolicy.Fix?
    @ObservationIgnored private var watchers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var sending: Set<String> = []
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "taption.tripLive.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        consents = (defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: TripLiveLocationConsent].self, from: $0) }) ?? [:]
    }

    private var store: TripShareStore { .shared }

    // MARK: 읽기

    func consent(_ tripID: String) -> TripLiveLocationConsent { consents[tripID] ?? TripLiveLocationConsent() }

    /// 지금의 서버 시각 추정(받은 시점의 서버 시각 + 그 뒤 흐른 시간).
    private func serverNow(_ tripID: String, now: Date = .now) -> Int? {
        guard let view = views[tripID], let at = capturedAt[tripID] else { return nil }
        return view.serverNow + Int(now.timeIntervalSince(at) * 1000)
    }

    func window(_ tripID: String) -> ShareLocWindow? { views[tripID]?.window }

    /// 지금이 위치를 보낼 수 있는 기간 안인가.
    func isInsideWindow(_ tripID: String, now: Date = .now) -> Bool {
        guard let window = window(tripID), let server = serverNow(tripID, now: now) else { return false }
        return window.contains(server)
    }

    func peers(_ tripID: String) -> [ShareReceivedLocation] { views[tripID]?.peers ?? [] }

    func freshness(_ location: ShareReceivedLocation, tripID: String, now: Date = .now) -> ShareLocationFreshness {
        ShareLocationFreshness(ageMs: max(0, (serverNow(tripID, now: now) ?? location.receivedAt) - location.receivedAt))
    }

    func minutesAgo(_ location: ShareReceivedLocation, tripID: String, now: Date = .now) -> Int {
        TripLiveLocationPolicy.minutesAgo(receivedAt: location.receivedAt, serverNow: serverNow(tripID, now: now) ?? location.receivedAt)
    }

    var myLocation: TripLiveLocationPolicy.Fix? { latest }

    /// 이 여행에서 도움을 요청한 동행(가장 최근 한 명).
    func helper(_ tripID: String) -> ShareReceivedLocation? { peers(tripID).filter(\.isHelp).max { $0.receivedAt < $1.receivedAt } }

    func meetPoint(_ tripID: String) -> ShareMeetContent? {
        for item in store.view(tripID: tripID)?.items ?? [] {
            if case .meet(let spot) = item.content, spot.on, spot.isValid { return spot }
        }
        return nil
    }

    /// 지도에 올릴 표시들(내 위치는 지도의 다른 층이 그리므로 넣지 않는다).
    func marks(tripID: String, language: MapHomeLanguage, now: Date = .now) -> [TravelCompanionMark] {
        _ = minuteTick
        guard Self.isAvailable, let view = store.view(tripID: tripID) else { return [] }
        let names = store.names(tripID: tripID)
        var out: [TravelCompanionMark] = peers(tripID).compactMap { peer in
            guard peer.payload.s.carriesCoordinate, let lat = peer.payload.lat, let lon = peer.payload.lon else { return nil }
            let name = names?.name(.member(peer.by)) ?? "\(peer.by)"
            let level = freshness(peer, tripID: tripID, now: now)
            let ago = TripLiveLocationPolicy.agoText(minutes: minutesAgo(peer, tripID: tripID, now: now), language)
            return TravelCompanionMark(
                id: "p\(peer.by)", kind: .person, initial: String(name.first ?? "?"), colorHex: view.cards[peer.by]?.color ?? "#5B7C99",
                longitude: lon, latitude: lat, caption: level == .lost ? language.text("연락 끊김?", "Lost?") + " " + ago : ago,
                opacity: TripLiveLocationPolicy.opacity(level), isHelp: peer.isHelp, accuracy: Double(peer.payload.acc ?? 0)
            )
        }
        if let spot = meetPoint(tripID) {
            out.append(TravelCompanionMark(
                id: "meet", kind: .meet, initial: "", colorHex: "#2F7D6D", longitude: spot.lon, latitude: spot.lat,
                caption: spot.name, opacity: 1, isHelp: false, accuracy: 0
            ))
        }
        return out
    }

    // MARK: 켜기·끄기·숨기기

    func setEnabled(_ enabled: Bool, tripID: String) async {
        guard Self.isAvailable else { return }
        var value = consent(tripID)
        value.enabled = enabled
        value.hiddenUntil = nil
        value.enabledAt = enabled ? .now : nil
        save(tripID, value)
        if enabled {
            await watch(tripID: tripID)
            if let latest { await send(tripID, fix: latest, force: true) }
            startLoop()
        } else {
            await stopSending(tripID)
        }
    }

    /// 잠깐 숨기기. `nil`이면 이 여행의 위치 기간이 끝날 때까지.
    func hide(tripID: String, for duration: TimeInterval?) async {
        var value = consent(tripID)
        guard value.enabled else { return }
        let end = duration.map { Date.now.addingTimeInterval($0) }
            ?? window(tripID).map { Date(timeIntervalSince1970: Double($0.until) / 1000) } ?? Date.now.addingTimeInterval(86_400)
        value.hiddenUntil = end
        save(tripID, value)
        await stopSending(tripID)
    }

    func unhide(tripID: String) async {
        var value = consent(tripID)
        value.hiddenUntil = nil
        save(tripID, value)
        if let latest { await send(tripID, fix: latest, force: true) }
    }

    private func stopSending(_ tripID: String) async {
        lastSent[tripID] = nil
        try? await store.session(tripID: tripID)?.stopLocation()
    }

    private func save(_ tripID: String, _ value: TripLiveLocationConsent) {
        consents[tripID] = value
        if let data = try? JSONEncoder().encode(consents) { defaults.set(data, forKey: Self.key) }
    }

    // MARK: 도와주세요·모이는 곳

    enum HelpResult { case sent, noLocation, closed, failed }

    /// 동행 모두에게 내 위치와 도움 요청을 보낸다. 켜 놓지 않았어도 여행 기간 안이면 보낼 수 있다.
    func sendHelp(tripID: String, note: String) async -> HelpResult {
        guard Self.isAvailable else { return .closed }
        guard let fix = latest, Date.now.timeIntervalSince(fix.at) < TripLiveLocationPolicy.freshForHelp else { return .noLocation }
        guard let session = await store.open(tripID: tripID) else { return .failed }
        await watch(tripID: tripID)
        guard isInsideWindow(tripID) else { return .closed }
        let payload = ShareLocationPayload(
            state: .help, latitude: fix.latitude, longitude: fix.longitude, accuracy: Int(fix.accuracy.rounded(.up)),
            at: TripLiveLocationPolicy.millis(fix.at), note: note.isEmpty ? nil : note
        )
        do { try await session.sendLocation(payload) } catch { return .failed }
        helpTrips.insert(tripID)
        return .sent
    }

    /// 「괜찮아졌어요」: 도움 요청을 거두고, 공유 중이면 보통 위치로 돌아간다.
    func clearHelp(tripID: String) async {
        helpTrips.remove(tripID)
        if consent(tripID).isSending(at: .now), let latest {
            await send(tripID, fix: TripLiveLocationPolicy.Fix(latitude: latest.latitude, longitude: latest.longitude, accuracy: latest.accuracy, at: .now), force: true)
        } else {
            try? await store.session(tripID: tripID)?.stopLocation()
        }
    }

    /// 모이는 곳을 정한다(누구나). 내 현재 위치나 넘겨 준 좌표를 쓴다.
    func setMeet(tripID: String, name: String, latitude: Double, longitude: Double, at: Date?) async -> Bool {
        guard let session = await store.open(tripID: tripID), let me = store.view(tripID: tripID)?.me else { return false }
        let spot = ShareMeetContent(name: name, latitude: latitude, longitude: longitude, at: at.map(TripLiveLocationPolicy.millis), by: me)
        return await writeMeet(session, spot)
    }

    func clearMeet(tripID: String) async {
        guard let session = store.session(tripID: tripID), let spot = meetPoint(tripID) else { return }
        _ = await writeMeet(session, spot.cleared)
    }

    private func writeMeet(_ session: ShareRoomSession, _ spot: ShareMeetContent) async -> Bool {
        let exists = await session.item(ShareMeetContent.itemID) != nil
        let edit: ShareEdit = exists
            ? .update(id: ShareMeetContent.itemID, content: .meet(spot))
            : .create(id: ShareMeetContent.itemID, content: .meet(spot), group: nil)
        guard let outcome = try? await session.write([edit]), outcome == .done else { return false }
        if let link = store.link(roomID: session.roomID) { await store.refresh(tripID: link.tripID) }
        return true
    }

    /// 주인만: 위치를 보낼 수 있는 기간을 바꾼다.
    func setWindow(tripID: String, from: Date, until: Date) async -> Bool {
        guard let session = store.session(tripID: tripID), until > from else { return false }
        let window = ShareLocWindow(from: TripLiveLocationPolicy.millis(from), until: TripLiveLocationPolicy.millis(until))
        guard (try? await session.setLocationWindow(window)) != nil else { return false }
        await capture(tripID: tripID, session: session)
        return true
    }

    // MARK: 받기·보내기

    /// 이 여행의 방을 열고 동행 위치 변화를 듣는다. 주인이면 기간이 아직 없을 때 기본 기간(시작일 0시~종료일 24시)을 올린다.
    func watch(tripID: String) async {
        // 앱을 다시 켜면 저장된 켬만 남고 점검은 멈춰 있다. 여행을 보거나 위치가 오면 다시 돌린다.
        if consent(tripID).enabled { startLoop() }
        guard Self.isAvailable, store.isShared(tripID), let session = await store.open(tripID: tripID) else { return }
        if watchers[tripID] == nil {
            watchers[tripID] = Task { [weak self] in
                for await _ in session.locationEvents {
                    guard let self, !Task.isCancelled else { return }
                    await self.capture(tripID: tripID, session: session)
                }
            }
        }
        await capture(tripID: tripID, session: session)
        if views[tripID]?.window == nil, store.link(tripID: tripID)?.role == .owner,
           let meta = store.view(tripID: tripID)?.meta,
           let window = TripLiveLocationPolicy.defaultWindow(startDay: meta.startDay, endDay: meta.endDay, timeZoneID: meta.timeZone) {
            try? await session.setLocationWindow(window)
            await capture(tripID: tripID, session: session)
        }
    }

    private func capture(tripID: String, session: ShareRoomSession) async {
        let view = await session.locationView()
        guard views[tripID] != view else { return }
        views[tripID] = view
        capturedAt[tripID] = .now
    }

    /// 앱이 켜지거나 앞으로 올 때: 켠 여행의 방을 열어 듣는다.
    func reconcile() async {
        guard Self.isAvailable else { return }
        for link in store.links where link.phase == .sharing {
            if consent(link.tripID).enabled || link.role == .owner { await watch(tripID: link.tripID) }
        }
        if consents.values.contains(where: \.enabled) { startLoop() }
    }

    /// 수집기가 받은 위치 한 점. 켠 여행마다 정책에 맞을 때만 보낸다.
    func offer(_ location: CLLocation) {
        guard Self.isAvailable, location.horizontalAccuracy >= 0 else { return }
        let fix = TripLiveLocationPolicy.Fix(location)
        latest = fix
        for (tripID, value) in consents where value.isSending(at: .now) {
            startLoop()
            Task { await send(tripID, fix: fix, force: false) }
        }
    }

    /// 이 기기에서 방을 잊을 때(`TripShareStore.forget`): 그 여행의 켬·받은 위치·듣기를 모두 지운다.
    /// 같은 여행을 새 방으로 다시 공유하거나 다시 들어와도 본인이 다시 켜야 위치가 나간다.
    func forget(tripID: String) {
        watchers.removeValue(forKey: tripID)?.cancel()
        views[tripID] = nil
        capturedAt[tripID] = nil
        lastSent[tripID] = nil
        helpTrips.remove(tripID)
        guard consents[tripID] != nil else { return }
        consents[tripID] = nil
        if let data = try? JSONEncoder().encode(consents) { defaults.set(data, forKey: Self.key) }
    }

    private func send(_ tripID: String, fix: TripLiveLocationPolicy.Fix, force: Bool) async {
        guard store.isShared(tripID), !sending.contains(tripID), consent(tripID).isSending(at: .now) else { return }
        let foreground = UIApplication.shared.applicationState == .active
        guard force || TripLiveLocationPolicy.shouldSend(fix, last: lastSent[tripID], isForeground: foreground) else { return }
        sending.insert(tripID)
        defer { sending.remove(tripID) }
        guard let session = await store.open(tripID: tripID) else { return }
        await watch(tripID: tripID)
        // 기기에서도 기간을 지킨다(서버가 한 번 더 막는다). 밖이면 아무것도 보내지 않는다.
        guard isInsideWindow(tripID) else { return }
        let payload = ShareLocationPayload(
            state: helpTrips.contains(tripID) ? .help : .ok, latitude: fix.latitude, longitude: fix.longitude,
            accuracy: Int(fix.accuracy.rounded(.up)), at: TripLiveLocationPolicy.millis(fix.at)
        )
        if (try? await session.sendLocation(payload)) != nil { lastSent[tripID] = fix }
    }

    // MARK: 주기 점검

    /// 30초마다: 멈춰 있어도 5분마다 한 번 알리고, 기간이 끝났으면 끈다, 「몇 분 전」을 새로 그린다.
    var isTicking: Bool { loop != nil }

    private func startLoop() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                await self.tick()
            }
        }
    }

    private func tick() async {
        minuteTick = Int(Date.now.timeIntervalSince1970 / 60)
        for (tripID, value) in consents where value.enabled {
            if let window = window(tripID), let server = serverNow(tripID), server >= window.until {
                await setEnabled(false, tripID: tripID)
                notice = "위치 공유가 끝났어요. 여행 기간이 지났어요."
                continue
            }
            guard value.isSending(at: .now), let latest, Date.now.timeIntervalSince(latest.at) < 600 else { continue }
            await send(tripID, fix: TripLiveLocationPolicy.Fix(latitude: latest.latitude, longitude: latest.longitude, accuracy: latest.accuracy, at: .now), force: false)
        }
        if !consents.values.contains(where: \.enabled) { loop?.cancel(); loop = nil }
    }
}
