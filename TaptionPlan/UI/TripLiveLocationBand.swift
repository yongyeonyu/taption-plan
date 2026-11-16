import SwiftUI
import TaptionTripShare

/// 여행 화면의 위치 공유 띠(LOC1116S01). 공유 중임을 늘 보이고, 누르면 시트에서 켜기·숨기기·도와주세요·모이는 곳을 다룬다.
/// 공유하지 않는 여행, 그리고 위치 기간 밖의 동행(주인이 아닌 사람)에게는 아무것도 그리지 않는다.
struct TripLiveLocationBand: View {
    let language: MapHomeLanguage
    let tripID: String
    @State private var showsSheet = false

    private var service: TripLiveLocationService { .shared }

    var body: some View {
        Group {
            if TripLiveLocationService.isAvailable, TripShareStore.shared.isShared(tripID) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let state = state(at: context.date) { capsule(state) }
                }
            }
        }
        .task(id: TripShareStore.shared.isShared(tripID)) {
            if TripShareStore.shared.isShared(tripID) { await service.watch(tripID: tripID) }
        }
        .sheet(isPresented: $showsSheet) { TripLiveLocationSheet(language: language, tripID: tripID) }
    }

    private enum BandState { case help(name: String, minutes: Int), sharing(count: Int), hidden(until: Date), off, outside }

    private func state(at now: Date) -> BandState? {
        let names = TripShareStore.shared.names(tripID: tripID)
        if let helper = service.helper(tripID) {
            return .help(name: names?.name(.member(helper.by)) ?? "", minutes: service.minutesAgo(helper, tripID: tripID, now: now))
        }
        let consent = service.consent(tripID)
        let inside = service.isInsideWindow(tripID, now: now)
        if consent.isHidden(at: now), let until = consent.hiddenUntil { return .hidden(until: until) }
        if consent.enabled, inside { return .sharing(count: max(0, (TripShareStore.shared.memberCount(tripID: tripID) ?? 1) - 1)) }
        if inside { return .off }
        return TripShareStore.shared.link(tripID: tripID)?.role == .owner ? .outside : nil
    }

    private func capsule(_ state: BandState) -> some View {
        Button { showsSheet = true } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(state)).font(.caption.weight(.semibold)).foregroundStyle(tint(state))
                Text(text(state)).font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption2)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(TravelInk.panel, in: RoundedRectangle(cornerRadius: TaptionCorner.small))
            .overlay { RoundedRectangle(cornerRadius: TaptionCorner.small).stroke(tint(state).opacity(0.5), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("travelLiveLocationBand")
    }

    private func icon(_ state: BandState) -> String {
        switch state {
        case .help: "exclamationmark.triangle.fill"
        case .sharing: "location.fill"
        case .hidden: "location.slash"
        case .off, .outside: "location"
        }
    }

    private func tint(_ state: BandState) -> Color {
        switch state {
        case .help: .red
        case .sharing: .green
        default: .secondary
        }
    }

    private func text(_ state: BandState) -> String {
        switch state {
        case .help(let name, let minutes):
            language.runtimeText("\(name)님이 도움을 요청했어요 · \(TripLiveLocationPolicy.agoText(minutes: minutes, language))", "\(name) asked for help · \(TripLiveLocationPolicy.agoText(minutes: minutes, language))")
        case .sharing(let count):
            language.runtimeText("내 위치 공유 중 · 동행 \(count)명에게", "Sharing my location · with \(count) companions")
        case .hidden(let until):
            language.runtimeText("위치 숨김 중 · \(until.formatted(date: .omitted, time: .shortened))까지", "Location hidden · until \(until.formatted(date: .omitted, time: .shortened))")
        case .off: language.text("내 위치 공유 꺼짐 · 켜기", "Location sharing off · turn on")
        case .outside: language.text("위치 공유 기간 설정", "Location sharing period")
        }
    }
}

/// 위치 공유 시트: 켜기·1시간 숨기기·도와주세요·동행 목록·모이는 곳·(주인) 기간.
struct TripLiveLocationSheet: View {
    let language: MapHomeLanguage
    let tripID: String
    @Environment(\.dismiss) private var dismiss
    @State private var asksConsent = false
    @State private var confirmsHelp = false
    @State private var helpNote = ""
    @State private var message: String?
    @State private var meetName = ""
    @State private var from = Date.now
    @State private var until = Date.now

    private var service: TripLiveLocationService { .shared }
    private var isOwner: Bool { TripShareStore.shared.link(tripID: tripID)?.role == .owner }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                List {
                    sharingSection(context.date)
                    helpSection
                    companionsSection(context.date)
                    meetSection
                    if isOwner { windowSection }
                    Section { Text(language.text("긴급 신고(112·119·현지 번호)를 대신하지 못해요. 앱이 꺼졌거나 통신이 없으면 위치가 오지 않아요.", "This does not replace emergency calls. If the app is closed or there is no signal, locations will not arrive.")).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(language.text("동행 위치", "Companion locations"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(language.text("닫기", "Close")) { dismiss() } } }
            .alert(language.text("위치 공유를 켤까요?", "Turn on location sharing?"), isPresented: $asksConsent) {
                Button(language.text("켜기", "Turn on")) { Task { await service.setEnabled(true, tripID: tripID) } }
                Button(language.text("취소", "Cancel"), role: .cancel) {}
            } message: {
                Text(language.text("이 여행의 동행에게만, 여행 기간 동안 내 현재 위치(위도·경도·정확도)가 보여요. 내용은 암호화되어 서버도 읽지 못하고, 서버는 마지막 위치 1건만 10분 동안 두며 이력은 남기지 않아요. 언제든 끄거나 1시간 숨길 수 있고, 여행이 끝나면 자동으로 꺼져요.", "Only companions on this trip can see your current location, only during the trip. It is encrypted, so the server cannot read it. The server keeps only your last location for 10 minutes and no history. Turn it off or hide it any time; it stops automatically after the trip."))
            }
            .confirmationDialog(language.text("동행 모두에게 내 위치와 도움 요청을 보낼까요?", "Send your location and a help request to everyone?"), isPresented: $confirmsHelp, titleVisibility: .visible) {
                Button(language.text("도와주세요 보내기", "Send help request"), role: .destructive) { Task { await sendHelp() } }
                Button(language.text("취소", "Cancel"), role: .cancel) {}
            } message: {
                Text(language.text("긴급 신고를 대신하지 못해요. 위급하면 먼저 112·119 또는 현지 긴급 번호로 연락하세요.", "This does not replace emergency calls. If it is urgent, call local emergency services first."))
            }
            .onAppear {
                if let window = service.window(tripID) {
                    from = Date(timeIntervalSince1970: Double(window.from) / 1000)
                    until = Date(timeIntervalSince1970: Double(window.until) / 1000)
                }
            }
        }
    }

    // MARK: 구역

    private func sharingSection(_ now: Date) -> some View {
        let consent = service.consent(tripID)
        let inside = service.isInsideWindow(tripID, now: now)
        return Section {
            Toggle(language.text("내 위치를 동행에게 공유", "Share my location with companions"), isOn: Binding(
                get: { consent.enabled },
                set: { on in if on { asksConsent = true } else { Task { await service.setEnabled(false, tripID: tripID) } } }
            ))
            .disabled(!inside && !consent.enabled)
            if consent.enabled {
                if consent.isHidden(at: now) {
                    Button(language.text("숨김 풀기", "Stop hiding")) { Task { await service.unhide(tripID: tripID) } }
                } else {
                    Button(language.text("1시간 숨기기", "Hide for 1 hour")) { Task { await service.hide(tripID: tripID, for: 3600) } }
                    Button(language.text("여행이 끝날 때까지 숨기기", "Hide until the trip ends")) { Task { await service.hide(tripID: tripID, for: nil) } }
                }
                if service.myLocation == nil {
                    Label(language.text("아직 내 위치를 받지 못했어요(위치 권한·수집을 확인해 주세요).", "No location fix yet (check location permission and collection)."), systemImage: "exclamationmark.circle").font(.footnote)
                }
            }
        } footer: {
            Text(inside ? language.text("지금은 위치를 보낼 수 있는 기간이에요.", "The sharing period is active.") : language.text("위치 공유 기간이 아니에요. 주인이 정한 기간에만 켤 수 있어요.", "Outside the sharing period. It can only be turned on during the period the owner set."))
        }
    }

    private var helpSection: some View {
        Section {
            TextField(language.text("한마디(선택, 40자)", "Short note (optional)"), text: $helpNote)
                .onChange(of: helpNote) { _, value in if value.count > TripLiveLocationPolicy.helpNoteLimit { helpNote = String(value.prefix(TripLiveLocationPolicy.helpNoteLimit)) } }
            Button(role: .destructive) { confirmsHelp = true } label: {
                Label(language.text("도와주세요", "Ask for help"), systemImage: "exclamationmark.triangle.fill")
            }
            if service.helpTrips.contains(tripID) {
                Button(language.text("괜찮아졌어요", "I'm okay now")) { Task { await service.clearHelp(tripID: tripID) } }
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func companionsSection(_ now: Date) -> some View {
        let peers = service.peers(tripID).filter { $0.payload.s.carriesCoordinate }
        let names = TripShareStore.shared.names(tripID: tripID)
        return Section(language.text("동행", "Companions")) {
            if peers.isEmpty { Text(language.text("위치를 공유 중인 동행이 아직 없어요.", "No companion is sharing yet.")).foregroundStyle(.secondary) }
            ForEach(peers) { peer in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(names?.name(.member(peer.by)) ?? "\(peer.by)").font(.body.weight(.medium))
                        if peer.isHelp { Text(language.text("도움 요청", "Help")).font(.caption2.weight(.bold)).foregroundStyle(.red) }
                        Spacer()
                        Text(TripLiveLocationPolicy.agoText(minutes: service.minutesAgo(peer, tripID: tripID, now: now), language)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(detail(peer, now)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func detail(_ peer: ShareReceivedLocation, _ now: Date) -> String {
        var parts: [String] = []
        if let accuracy = peer.payload.acc { parts.append(language.runtimeText("정확도 약 \(accuracy)m", "accuracy ~\(accuracy) m")) }
        if service.freshness(peer, tripID: tripID, now: now) == .lost { parts.append(language.text("연락 끊김?", "Lost contact?")) }
        if let note = peer.payload.note { parts.append(note) }
        if let mine = service.myLocation, let lat = peer.payload.lat, let lon = peer.payload.lon {
            let meters = ShareLocationMath.distanceMeters((mine.latitude, mine.longitude), (lat, lon))
            parts.append(distanceText(meters))
        }
        return parts.joined(separator: " · ")
    }

    private func distanceText(_ meters: Double) -> String {
        let walk = ShareLocationMath.walkingMinutes(meters: meters)
        let far = meters >= 1000 ? String(format: "%.1fkm", meters / 1000) : "\(Int(meters.rounded()))m"
        return language.runtimeText("직선 \(far) · 걸어서 약 \(walk)분", "\(far) away · ~\(walk) min walk")
    }

    private var meetSection: some View {
        Section(language.text("모이는 곳", "Meeting point")) {
            if let spot = service.meetPoint(tripID) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(spot.name, systemImage: "flag.fill")
                    if let at = spot.at { Text(Date(timeIntervalSince1970: Double(at) / 1000).formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    if let mine = service.myLocation {
                        Text(distanceText(ShareLocationMath.distanceMeters((mine.latitude, mine.longitude), (spot.lat, spot.lon)))).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button(language.text("해제", "Clear"), role: .destructive) { Task { await service.clearMeet(tripID: tripID) } }
            }
            TextField(language.text("이름(예: 역 앞 광장)", "Name (e.g. station plaza)"), text: $meetName)
            Button(language.text("내 위치를 모이는 곳으로", "Use my location as the meeting point")) {
                Task {
                    guard let mine = service.myLocation else { message = language.text("내 위치를 아직 받지 못했어요.", "No location fix yet."); return }
                    let ok = await service.setMeet(tripID: tripID, name: meetName.isEmpty ? language.text("모이는 곳", "Meeting point") : meetName, latitude: mine.latitude, longitude: mine.longitude, at: nil)
                    message = ok ? nil : language.text("정하지 못했어요. 위치 공유 기간 안인지 확인해 주세요.", "Could not set it. Check that it is inside the sharing period.")
                }
            }
            .disabled(service.myLocation == nil)
        }
    }

    private var windowSection: some View {
        Section {
            DatePicker(language.text("시작", "From"), selection: $from)
            DatePicker(language.text("끝", "Until"), selection: $until)
            Button(language.text("기간 저장", "Save period")) {
                Task { message = await service.setWindow(tripID: tripID, from: from, until: until) ? nil : language.text("저장하지 못했어요(40일 이하, 끝이 시작보다 뒤).", "Could not save (max 40 days, end after start).") }
            }
        } header: {
            Text(language.text("위치 공유 기간(주인)", "Sharing period (owner)"))
        } footer: {
            Text(language.text("기본은 여행 시작일 0시 ~ 종료일 24시예요. 이 기간 밖에는 위치가 나가지 않아요.", "By default: start day 00:00 to end day 24:00. No location leaves the device outside this period."))
        }
    }

    private func sendHelp() async {
        switch await service.sendHelp(tripID: tripID, note: helpNote) {
        case .sent: message = language.text("동행에게 보냈어요. 긴급 신고는 따로 해 주세요.", "Sent to your companions. Please also call emergency services if needed.")
        case .noLocation: message = language.text("내 위치를 아직 받지 못했어요.", "No recent location fix.")
        case .closed: message = language.text("위치 공유 기간이 아니에요.", "Outside the sharing period.")
        case .failed: message = language.text("보내지 못했어요. 통신을 확인해 주세요.", "Could not send. Check your connection.")
        }
    }
}
