import MapKit
import SwiftUI
import TaptionPlanCore

extension AppModel {
    /// AI 여행을 반영한다. 같은 여행이 있으면 지우고 새로 넣는다(대표 결정: 바뀐 것 표시 후 교체).
    /// 반영하지 못하면 false. 그때는 서버에 도착한 계획을 지우지 않는다(REV1110A06).
    @discardableResult
    func applyTripImport(_ incoming: TripImportPlan) async -> Bool {
        guard acceptsDataMutation() else { return false }
        // 다시 가져온 계획에 상태가 없으면 사용자가 정한 상태를 지킨다.
        let plan = incoming.keepingUserStatus(from: snapshot.settings.travelTripItems ?? [])
        // 핀이 없는 일정(수면·좌표 없음)도 계획이 있으니 여행 일정 쪽 planID까지 함께 지운다.
        let oldPlanIDs = Set(
            snapshot.settings.travelPlanStops.filter { $0.tripID == plan.tripID }.compactMap(\.planID)
                + (snapshot.settings.travelTripItems ?? []).filter { $0.tripID == plan.tripID }.compactMap(\.planID)
        )
        snapshot.settings.travelPlanStops = TravelPlanSchedule.renumbered(snapshot.settings.travelPlanStops.filter { $0.tripID != plan.tripID })
        await deletePlans(Array(oldPlanIDs))
        let calendar = Calendar.autoupdatingCurrent
        var stops = snapshot.settings.travelPlanStops
        var tripItems = (snapshot.settings.travelTripItems ?? []).filter { $0.tripID != plan.tripID }
        for item in plan.items {
            let planID = addPlan(
                title: item.title,
                categoryID: item.kind.categoryID,
                middleCategoryName: item.kind.planName,
                startAt: item.start,
                duration: item.end.timeIntervalSince(item.start)
            )
            tripItems.append(TravelTripItem(
                tripID: plan.tripID, itemID: item.id, kind: item.kind.rawValue, title: item.title,
                start: item.start, end: item.end,
                startOffsetSeconds: item.timeZone.secondsFromGMT(for: item.start),
                endOffsetSeconds: item.endTimeZone.secondsFromGMT(for: item.end), planID: planID, status: item.status.stored
            ))
            // 잠은 숙소 자리라 지도에 핀을 따로 찍지 않는다.
            guard item.kind != .sleep, let coordinate = item.coordinate else { continue }
            let day = item.localDay(calendar: calendar)
            stops.append(TravelPlanStop(
                id: UUID(), title: item.title, latitude: coordinate.latitude, longitude: coordinate.longitude,
                day: day, order: TravelPlanSchedule.stops(on: day, in: stops).count, planID: planID,
                tripID: plan.tripID, itemID: item.id, status: item.status.stored
            ))
        }
        snapshot.settings.travelPlanStops = stops
        snapshot.settings.travelTripItems = tripItems.isEmpty ? nil : tripItems
        return await persist()
    }

    func tripImportDiff(for plan: TripImportPlan) -> TripImportDiff? {
        TripImportDiff.make(plan: plan, existing: snapshot.settings.travelTripItems ?? [])
    }
}

/// 여행 일정을 시간 막대에 놓는다. 각 일정은 그곳의 벽시계 시각에 놓여, 항공편 도착부터 현지 시각이 된다.
enum TravelTripRail {
    static func segments(_ items: [TravelTripItem], day: Date, calendar: Calendar = .autoupdatingCurrent) -> [MapHomeTimeRailSegment] {
        let target = calendar.dateComponents([.year, .month, .day], from: day)
        return items.compactMap { item in
            let start = wallClock(item.start, offset: item.startOffsetSeconds)
            let end = wallClock(item.end, offset: item.endOffsetSeconds)
            let startMinute = start.day == target ? start.minute : start.day < target ? 0 : nil
            let endMinute = end.day == target ? end.minute : end.day > target ? 1_440 : nil
            guard let startMinute, let endMinute, endMinute > startMinute else { return nil }
            var segment = MapHomeTimeRailSegment(
                startMinute: startMinute, endMinute: endMinute,
                categoryID: railCategory(item.kind), title: item.title, sourceID: item.planID
            )
            segment.tripStatus = TripItemStatus(raw: item.status) // 계획은 그대로 그린다(TRP1110A09).
            return segment
        }
        .sorted { $0.startMinute < $1.startMinute }
    }

    private struct WallClock {
        let day: DateComponents
        let minute: Int
    }

    private static func wallClock(_ date: Date, offset: Int) -> WallClock {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(secondsFromGMT: offset) ?? .current
        let parts = local.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return WallClock(day: DateComponents(year: parts.year, month: parts.month, day: parts.day), minute: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    static func railCategory(_ kind: String) -> String {
        switch TripImportItem.Kind(rawValue: kind) ?? .other {
        case .flight, .transfer: "movement"
        case .sleep: "sleep"
        case .meal, .cafe: "eating"
        case .activity: "exercise"
        case .sight, .photo, .shopping: "hobby"
        case .lodging, .rest, .other: "activity"
        }
    }
}

private func < (lhs: DateComponents, rhs: DateComponents) -> Bool {
    (lhs.year ?? 0, lhs.month ?? 0, lhs.day ?? 0) < (rhs.year ?? 0, rhs.month ?? 0, rhs.day ?? 0)
}

private func > (lhs: DateComponents, rhs: DateComponents) -> Bool { rhs < lhs }

extension MapHomeView {
    /// 여행 모드에서 가져온 여행이 있는 날은 기록 대신 여행 일정을 시간 막대에 그린다.
    var travelSidebarSegments: [MapHomeTimeRailSegment]? {
        guard isTravelMode, let items = model.settings.travelTripItems, !items.isEmpty else { return nil }
        let segments = TravelTripRail.segments(items, day: model.selectedDate)
        return segments.isEmpty ? nil : segments
    }
}

extension TripImportItem.Kind {
    var planName: String {
        let language = MapHomeLanguage.current
        switch self {
        case .flight: return language.text("항공편", "Flight")
        case .lodging: return language.text("숙소", "Lodging")
        case .meal: return language.text("식사", "Meal")
        case .cafe: return language.text("카페", "Cafe")
        case .photo: return language.text("사진 명소", "Photo spot")
        case .activity: return language.text("활동", "Activity")
        case .rest: return language.text("휴식", "Rest")
        case .sleep: return language.text("수면", "Sleep")
        case .sight: return language.text("관광", "Sightseeing")
        case .shopping: return language.text("쇼핑", "Shopping")
        case .transfer: return language.text("이동", "Transfer")
        case .other: return language.text("기타", "Other")
        }
    }

    /// 시간표 줄. 잠은 수면, 휴식은 휴식, 이동은 이동 줄에 놓인다.
    var categoryID: String {
        switch self {
        case .flight, .transfer: "movement"
        case .sleep: "sleep"
        case .rest: "rest"
        default: "travel"
        }
    }

    var symbol: String {
        switch self {
        case .flight: "airplane"
        case .lodging: "bed.double.fill"
        case .meal: "fork.knife"
        case .cafe: "cup.and.saucer.fill"
        case .photo: "camera.viewfinder"
        case .activity: "figure.pool.swim"
        case .rest: "sofa.fill"
        case .sleep: "moon.zzz.fill"
        case .sight: "camera.fill"
        case .shopping: "bag.fill"
        case .transfer: "tram.fill"
        case .other: "mappin"
        }
    }
}

/// 여행 모드 → 추가 → AI로 만들기(TRP1110A01). AI 앱에서 대화하고, 받은 JSON을 붙여 넣어 미리 본 뒤 반영한다.
struct MapHomeTripImportSheet: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    /// 앱으로 돌아와 배너에서 붙여 넣은 글. 있으면 열자마자 미리보기를 보인다.
    var initialText: String?
    var onApplied: (Date) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var pasted = ""
    @State private var plan: TripImportPlan?
    @State private var diff: TripImportDiff?
    @State private var message: String?
    @State private var copiedFor: TripImportAIApp?
    /// 피클을 누른 뒤 안내. 중계 구역에서 눌렀으면 그 아래에 보인다(TRP1110A08).
    @State private var pickleNote: (text: String, inRelay: Bool)?
    /// 복사한 뒤 AI를 열기 전에 「붙여 넣어 주세요」를 보이는 창. PIN 시트가 떠 있으면 닫힌 뒤에 띄운다.
    @State private var pasteGuide: TripPasteGuide?
    @State private var pendingPasteGuide: TripPasteGuide?
    @State private var isResolving = false
    @State private var isApplying = false
    @State private var applyMessage: String?

    @State private var isLoadingRelay = false
    /// 프롬프트에 넣은 그 AI의 연결 키. 주 키는 넣지 않는다(SEC1110A02).
    @State private var promptKey: String?
    @State private var store = AssistantConnectionStore()
    /// 연결 키가 없어 PIN을 묻는 중인 AI. 취소하면 키 없이 복사한다.
    @State private var pinApp: TripImportAIApp?
    @State private var pendingApp: (app: TripImportAIApp, inRelay: Bool)?

    private func prompt(key: String?) -> String {
        let base = TripImportPrompt.text(languageCode: TripImportPrompt.currentLanguageCode)
        guard let endpoint = TripRelay.endpoint, let key else { return base }
        return base + TripRelay.deliveryInstruction(endpoint: endpoint, key: key)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(language.text("AI로 여행 계획 만들기", "Plan a trip with AI"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.headline), weight: .bold))
                talkStep
                if TripRelay.isAvailable { relayStep }
                pasteStep
                if let plan { preview(plan) }
            }
            .padding(20)
        }
        .background(Color.tpBackground)
        .onAppear {
            guard plan == nil, let initialText else { return }
            read(initialText)
        }
        .alert(language.text("프롬프트를 복사했어요", "Prompt copied"), isPresented: Binding(
            get: { pasteGuide != nil }, set: { if !$0 { pasteGuide = nil } }
        ), presenting: pasteGuide) { guide in
            Button(language.text("\(guide.name) 열기", "Open \(guide.name)")) { openURL(guide.url) }
            Button(language.text("취소", "Cancel"), role: .cancel) {}
        } message: { guide in
            Text(guide.hasKey
                 ? language.text("\(guide.name) 채팅창에 붙여 넣고 보내 주세요. 연결 키가 들어 있어 계획이 앱으로 바로 와요. 클립보드는 10분 뒤 지워져요.",
                                 "Paste it into the \(guide.name) chat and send. It includes a connection key, so the plan comes straight to the app. The clipboard is cleared in 10 minutes.")
                 : language.text("\(guide.name) 채팅창에 붙여 넣고 보내 주세요.", "Paste it into the \(guide.name) chat and send."))
        }
        .sheet(item: $pinApp, onDismiss: {
            if let pendingPasteGuide {
                pasteGuide = pendingPasteGuide
                self.pendingPasteGuide = nil
            }
            // PIN을 넣지 않고 닫으면 키 없이 복사하고 연다.
            if let pending = pendingApp { finishOpen(pending.app, key: nil, inRelay: pending.inRelay) }
        }) { app in
            let name = app.title(language)
            AssistantPINSheet.gate(language: language, purpose: language.text(
                "\(name)에 넣을 연결 키를 만들어요. 취소하면 키 없이 복사해요.",
                "Creates a connection key for \(name). Cancel to copy without a key."
            )) { pin in
                switch await store.create(for: app.provider, pin: pin, language: language) {
                case let .failure(text): return text
                case let .key(_, token):
                    let inRelay = pendingApp?.inRelay ?? false
                    pendingApp = nil
                    finishOpen(app, key: token, inRelay: inRelay)
                    return nil
                }
            }
        }
        #if DEBUG
        // 시뮬레이터 시험용: SIMCTL_CHILD_TRIP_IMPORT_SAMPLE=<파일>로 붙여 넣은 것처럼 읽는다.
        .onAppear {
            guard plan == nil, let path = ProcessInfo.processInfo.environment["TRIP_IMPORT_SAMPLE"],
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            read(text)
        }
        #endif
    }

    private var talkStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepTitle("1", language.text("AI와 대화하기", "Talk with an AI"))
            caption(language.text(
                "AI 앱이 열리면 객관식 질문에 답하며 항공편·숙소·관광지를 정해요. 마지막에 나오는 JSON을 복사해 돌아오세요.",
                "In the AI app, answer multiple-choice questions to pick flights, hotels and places. Copy the JSON it gives you at the end and come back."
            ))
            ForEach(TripImportAIApp.allCases) { app in
                let name = app.title(language)
                wideButton(app == .pickle
                    ? language.text("피클에서 계획 세우기 (자동 연동)", "Plan in Pickle (Auto Sync)")
                    : language.text("\(name)에서 계획 세우기", "Plan in \(name)"), prominent: app == .pickle) { open(app) }
                if app == .pickle, let pickleNote, !pickleNote.inRelay { caption(pickleNote.text) }
            }
            if let copiedFor, copiedFor != .pickle, !copiedFor.prefillsPrompt || promptKey != nil {
                let name = copiedFor.title(language)
                caption(language.text("프롬프트를 복사했어요. \(name)에 붙여 넣고 보내 주세요.", "The prompt is copied. Paste it into \(name) and send."))
            }
            wideButton(language.text("프롬프트만 복사", "Copy prompt only"), prominent: false) {
                // 키 없는 프롬프트. 키를 넣으려면 AI를 골라 연다.
                UIPasteboard.general.string = prompt(key: nil)
                TripClipboardWatch.promptCopied()
                message = language.text("프롬프트를 복사했어요.", "Prompt copied.")
            }
        }
    }

    /// AI 비서 자동 연결. 키를 만들면 프롬프트에 전달 주소가 붙고, 계획은 앱을 열 때 도착한다.
    private var relayStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(language.text("AI 비서가 앱으로 바로 보내기", "Let the AI send it to the app"), systemImage: "paperplane.fill")
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold))
                .foregroundStyle(Color.tpInk)
            caption(language.text(
                "웹 요청을 할 수 있는 AI 비서는 복사하지 않아도 계획을 보낼 수 있어요. AI를 고르면 그 AI의 연결 키가 프롬프트에 들어가고, 없으면 PIN을 물어 만들어요. 계획은 서버에 최대 3일 머물고 앱이 받으면 바로 지워져요.",
                "AI assistants that can make web requests can send the plan without copying. Pick an AI and its connection key goes into the prompt; if it has none, you're asked for your PIN to make one. Plans stay on the server for up to 3 days and are deleted as soon as the app receives them."
            ))
            wideButton(language.text("도착한 계획 불러오기", "Load the delivered plan"), prominent: false) { loadRelayPlan() }
                .disabled(isLoadingRelay)
            wideButton(language.text("피클 열기 / 받기", "Open / Get Pickle"), prominent: false) { open(.pickle, inRelay: true) }
            if let pickleNote, pickleNote.inRelay { caption(pickleNote.text) }
        }
    }

    private var pasteStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepTitle("2", language.text("받은 JSON 붙여 넣기", "Paste the JSON"))
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in read(text) }
            }
            .buttonBorderShape(.capsule)
            TextEditor(text: $pasted)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .background(Color.tpCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            wideButton(language.text("확인", "Check"), prominent: false) { read(pasted) }
                .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let message { caption(message) }
        }
    }

    private func preview(_ plan: TripImportPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle("3", language.text("확인하고 반영하기", "Review and add"))
            Text(plan.title).font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold))
            if let diff {
                caption(language.text(
                    "같은 여행이 있어 바꿉니다 · 추가 \(diff.added) · 변경 \(diff.changed) · 삭제 \(diff.removed)",
                    "Replaces the same trip · added \(diff.added) · changed \(diff.changed) · removed \(diff.removed)"
                ))
            }
            if isResolving { ProgressView().frame(maxWidth: .infinity) }
            let warnings = TripImportTimingCheck.warnings(plan.items)
            ForEach(plan.days(), id: \.day) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.day, format: .dateTime.month().day().weekday())
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .bold))
                    ForEach(group.items) { item in row(item, warning: warnings[item.id]) }
                }
            }
            wideButton(language.text("여행 계획에 반영", "Add to trip plan"), prominent: true) {
                isApplying = true
                applyMessage = nil
                let appliedText = pasted
                Task { @MainActor in
                    let applied = await model.applyTripImport(plan)
                    isApplying = false
                    guard applied else {
                        // 반영하지 못했으면 닫지 않고, 서버의 계획도 그대로 둔다.
                        applyMessage = language.text("지금은 반영하지 못했어요. 잠시 뒤 다시 해 주세요.", "Couldn't add it right now. Try again in a moment.")
                        return
                    }
                    TripClipboardWatch.clear()
                    // 중계에서 받은 바로 그 계획일 때만 서버에서 지운다. 기다리지 않는다.
                    if TripRelay.isLastReceived(appliedText) { Task { await TripRelay.clear() } }
                    onApplied(plan.items.first?.localDay() ?? .now)
                    dismiss()
                }
            }
            .disabled(isResolving || isApplying)
            if let applyMessage { caption(applyMessage) }
        }
    }

    private func row(_ item: TripImportItem, warning: TripImportTimingCheck.Warning? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.symbol).frame(width: 22).foregroundStyle(Color.tpInk)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(localTime(item.start, item.timeZone))–\(localTime(item.end, item.endTimeZone)) \(item.title)")
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                TripItemStatusBadge(status: item.status, language: language)
                if let minutes = item.travelMinutes, minutes > 0 {
                    caption(language.text("앞에서 이동 \(Int(minutes))분", "\(Int(minutes)) min from previous"))
                }
                if let warning {
                    Text(warningText(warning))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .semibold))
                        .foregroundStyle(.orange)
                }
                if item.coordinate == nil {
                    Text(language.text("위치를 찾지 못해 지도에는 표시되지 않아요", "Location not found; not shown on the map"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .semibold))
                        .foregroundStyle(.orange)
                }
                if let url = item.mapsURL {
                    Link(language.text("구글 지도에서 보기", "Open in Google Maps"), destination: url)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .semibold))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.tpCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func warningText(_ warning: TripImportTimingCheck.Warning) -> String {
        switch warning {
        case let .tightMove(need): language.text("이동 시간이 빠듯해요(약 \(need)분 필요)", "Tight move (about \(need) min needed)")
        case let .afterFlight(need): language.text("도착 뒤 입국·짐 찾기로 \(need)분은 두세요", "Allow \(need) min after landing for arrival")
        }
    }

    /// 현지 시각으로 보여 준다(방콕 도착은 방콕 시각).
    private func localTime(_ date: Date, _ timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// 그 AI의 연결 키를 찾고, 없으면 PIN을 물어 만든다(SEC1110A02). 중계가 없으면 키 없이 연다.
    private func open(_ app: TripImportAIApp, inRelay: Bool = false) {
        guard TripRelay.isAvailable else { return finishOpen(app, key: nil, inRelay: inRelay) }
        Task { @MainActor in
            if store.keys == nil { await store.reload() }
            if let found = store.token(for: app.provider), found.key.scope == .write {
                finishOpen(app, key: found.token, inRelay: inRelay)
            } else {
                pendingApp = (app, inRelay)
                pinApp = app
            }
        }
    }

    private func finishOpen(_ app: TripImportAIApp, key: String?, inRelay: Bool) {
        pendingApp = nil
        promptKey = key
        let text = prompt(key: key)
        if let key, let endpoint = TripRelay.endpoint {
            // 키는 글에 넣지 않고 1회용 주소(10분·3번)로 건넨다(SET1110A01). 서버에 닿지 못하면 키가 든 글을 이 기기에만 10분 둔다.
            let base = TripImportPrompt.text(languageCode: TripImportPrompt.currentLanguageCode)
            let delivery = TripRelay.deliveryInstruction(endpoint: endpoint, key: key)
            Task { AssistantClipboard.copy(await TripRelay.setupLinkText(for: delivery).map { base + "\n\n" + $0 } ?? text) }
        } else if key != nil {
            AssistantClipboard.copy(text)
        } else {
            UIPasteboard.general.string = text
        }
        TripClipboardWatch.promptCopied()
        copiedFor = app
        guard app == .pickle else {
            let prefills = app.prefillsPrompt && key == nil
            guard let url = app.url(prompt: prefills ? text : nil) else { return }
            // 프롬프트가 채워져 열리면 붙여 넣을 일이 없다.
            if prefills { openURL(url) } else { showPasteGuide(TripPasteGuide(name: app.title(language), url: url, hasKey: key != nil)) }
            return
        }
        // 피클은 앱이 없으면 App Store를 연다(TRP1110A08).
        let installed = AssistantAIProvider.pickle.isInstalled
        let note = !installed
            ? language.text("피클이 없어서 App Store를 열었어요. 설치한 뒤 다시 눌러 주세요.", "Pickle isn't installed, so the App Store opened. Install it and tap again.")
            : key != nil
                ? language.text("프롬프트와 피클 연결 키를 복사했어요. 피클 채팅창에 붙여 넣으면 계획이 앱으로 바로 와요.", "The prompt and Pickle's connection key are copied. Paste them into the Pickle chat and the plan comes straight to the app.")
                : language.text("프롬프트를 복사했어요. 피클에 붙여 넣고 보내 주세요.", "The prompt is copied. Paste it into Pickle and send.")
        pickleNote = (note, inRelay)
        guard let url = AssistantAIProvider.pickle.destination(installed: installed) else { return }
        // 피클이 없으면 붙여 넣을 곳이 없으니 App Store를 바로 연다.
        if installed { showPasteGuide(TripPasteGuide(name: AssistantAIProvider.pickle.title(language), url: url, hasKey: key != nil)) } else { openURL(url) }
    }

    private func showPasteGuide(_ guide: TripPasteGuide) {
        if pinApp != nil { pendingPasteGuide = guide } else { pasteGuide = guide }
    }

    /// 반영하지 않고 닫았던 계획도 서버에 남아 있으면(최대 3일) 다시 불러온다.
    private func loadRelayPlan() {
        isLoadingRelay = true
        Task { @MainActor in
            let text = await TripRelay.fetch()
            isLoadingRelay = false
            if let text {
                _ = TripRelay.isNew(text)
                read(text)
            } else {
                message = language.text("도착한 계획이 없어요.", "No plan has arrived.")
            }
        }
    }

    private func read(_ text: String) {
        pasted = text
        switch TripImportParser.parse(text) {
        case .success(let parsed):
            message = nil
            plan = parsed
            diff = model.tripImportDiff(for: parsed)
            Task { @MainActor in await resolveMissingPlaces() }
        case .failure(let error):
            plan = nil
            message = describe(error)
        }
    }

    /// AI가 좌표를 비운 곳은 이름·주소로 찾는다. 못 찾으면 시간 일정만 넣는다.
    private func resolveMissingPlaces() async {
        guard var current = plan, current.items.contains(where: { $0.coordinate == nil }) else { return }
        isResolving = true
        let anchor = current.items.compactMap(\.coordinate).first
        for index in current.items.indices where current.items[index].coordinate == nil {
            let item = current.items[index]
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = [item.placeName, item.address].filter { !$0.isEmpty }.joined(separator: " ")
            if let anchor { request.region = MKCoordinateRegion(center: anchor, latitudinalMeters: 200_000, longitudinalMeters: 200_000) }
            current.items[index].coordinate = try? await MKLocalSearch(request: request).start().mapItems.first?.placemark.coordinate
        }
        if plan?.tripID == current.tripID { plan = current }
        isResolving = false
    }

    private func describe(_ error: TripImportError) -> String {
        switch error {
        case .noJSON, .notTripFormat:
            return language.text("여행 계획 JSON이 아니에요. AI가 마지막에 준 JSON 전체를 복사해 주세요.", "This isn't trip JSON. Copy the whole JSON the AI gave at the end.")
        case .unreadable:
            return language.text("JSON 일부가 잘렸거나 형식이 달라요. AI에게 JSON을 다시 출력해 달라고 해 주세요.", "Part of the JSON is cut off or malformed. Ask the AI to output the JSON again.")
        case .unsupportedVersion:
            return language.text("앱보다 새 형식이에요. 앱을 업데이트해 주세요.", "This format is newer than the app. Please update the app.")
        case .empty:
            return language.text("일정이 비어 있어요.", "The trip has no items.")
        case .badTime(let itemID):
            return language.text("\(itemID) 항목의 시각을 읽지 못했어요.", "Couldn't read the time of item \(itemID).")
        }
    }

    private func stepTitle(_ number: String, _ title: String) -> some View {
        Text(verbatim: "\(number). \(title)")
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold))
            .foregroundStyle(Color.tpInk)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .medium))
            .foregroundStyle(Color.tpSecondary)
    }

    private func wideButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                .foregroundStyle(prominent ? Color.tpBackground : Color.tpInk)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(prominent ? Color.tpInk : Color.tpCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 여행 프롬프트를 복사한 뒤 열 AI.
struct TripPasteGuide: Equatable {
    var name: String
    var url: URL
    var hasKey: Bool
}
