import SwiftUI
import TaptionPlanStore

/// 항공편 찾기(FLT1119A01 → FLT1120A01). 스카이스캐너·구글 플라이트처럼 위에 조회 조건 카드, 아래에 결과 리스트.
/// 국내선(인천 제외 한국 공항끼리)은 출발 공항의 출발 조회와 도착 공항의 도착 조회를 합쳐 출발·도착 시각을 둘 다 보여 준다.
/// 서버로는 공항 코드·날짜·방향·편명만 보낸다. 못 받아도 오류 화면 없이 「직접 넣기」와 「항공사 알림 붙여넣기」가 남는다.
struct FlightPickerSheet: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let trip: TravelTrip
    /// 넣은 일정 번호를 알린다(되돌리기 기록용).
    var onAdded: (String) -> Void = { _ in }

    private enum Side: Identifiable { case from, to; var id: Int { self == .from ? 0 : 1 } }

    @Environment(\.dismiss) private var dismiss
    @AppStorage("flightDirectOnlyDomestic") private var directOnlyDomestic = true
    @AppStorage("flightDirectOnlyInternational") private var directOnlyInternational = false
    @State private var from = FlightPlacement.AirportChoice(code: "ICN", nameKo: "인천", nameEn: "Incheon")
    @State private var to: FlightPlacement.AirportChoice?
    @State private var day = ""
    @State private var sort = FlightSearch.Sort.departure
    @State private var side: Side?
    @State private var flightQuery = ""
    @State private var found: FlightSearch.Result?
    @State private var failure: FlightLookup.Failure?
    @State private var isLoading = false
    @State private var loadToken = 0
    @State private var isSaving = false
    @State private var didFail = false
    @State private var pasteUnreadable = false
    @State private var manualFlight = ""
    @State private var manualTime = Date(timeIntervalSince1970: 9 * 3_600)
    @State private var manualDuration = ""
    @State private var sourceIsLive = false

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private var isDomestic: Bool { FlightSearch.isDomestic(from.code, to?.code) }
    private var fromIsKorean: Bool { FlightSearch.isKorean(from.code) }
    private var isReturning: Bool { !fromIsKorean }
    private var direction: FlightLookup.Direction { isReturning ? .arr : .dep }
    private var koreanCode: String { fromIsKorean ? from.code : (to.map { FlightSearch.isKorean($0.code) ? $0.code : "ICN" } ?? "ICN") }
    private var directOnly: Bool { isDomestic ? directOnlyDomestic : directOnlyInternational }
    private var conditionKey: String { "\(from.code)|\(to?.code ?? "-")|\(day)" }

    private var stripDays: [String] {
        let today = TravelTripDay.string(for: .now, offsetSeconds: TimeZone.current.secondsFromGMT())
        var days: [String] = []
        for offset in -1...7 {
            if let start = TravelTripDay.components(today).flatMap({ calendar.date(from: $0) }),
               let date = calendar.date(byAdding: .day, value: offset, to: start) { days.append(TravelTripDay.string(for: date, offsetSeconds: 0)) }
        }
        if !day.isEmpty, !days.contains(day) { days = ([day] + days).sorted() }
        return days
    }

    private var rows: [FlightSearch.Row] {
        let query = flightQuery.replacingOccurrences(of: " ", with: "").uppercased()
        // 국제선은 한국 공항으로 조회하므로, 반대편 공항을 골랐으면 그 공항 편만 남긴다.
        let other = isDomestic ? nil : (fromIsKorean ? to : from)
        let base = (found?.rows ?? []).filter { row in
            if let other, (fromIsKorean ? row.listing.destination : row.listing.origin) != other.code { return false }
            return query.isEmpty || row.listing.flight.contains(query)
        }
        return FlightSearch.sorted(FlightSearch.filtered(base, directOnly: directOnly), by: sort)
    }

    var body: some View {
        NavigationStack {
            Form {
                searchCard
                resultSection
                pasteSection
                manualSection
                if didFail {
                    Section { Text(language.text("일정에 넣지 못했어요. 시각이나 공항을 확인해 주세요.", "Could not add it. Check the time and airports.")).foregroundStyle(.red) }
                }
            }
            .navigationTitle(language.text("항공편 찾기", "Find a flight"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(language.text("닫기", "Close")) { dismiss() } } }
            .onAppear { if day.isEmpty { applyDefaultDay() } }
            .sheet(item: $side) { which in
                FlightAirportSheet(
                    language: language,
                    title: which == .from ? language.text("출발 공항", "From") : language.text("도착 공항", "To"),
                    allowed: nil
                ) { airport in pick(airport, side: which) }
            }
            .task(id: conditionKey) {
                // 조건이 바뀌면 300ms 뒤 자동 조회. 늦게 온 옛 응답은 토큰으로 버린다.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await load()
            }
        }
        .accessibilityIdentifier("flightPickerSheet")
    }

    // MARK: 검색 카드

    private var searchCard: some View {
        Section {
            HStack(spacing: 8) {
                airportButton(from, side: .from, id: "flightAirportFrom", placeholder: language.text("출발", "From"))
                Button(action: swap) { Image(systemName: "arrow.left.arrow.right").frame(width: 44, height: 44) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.tpReferenceBlue)
                    .accessibilityIdentifier("flightSwap")
                airportButton(to, side: .to, id: "flightAirportTo", placeholder: language.text("도착", "To"))
            }
            if isDomestic {
                Text(language.text("국내선", "Domestic")).font(.caption.weight(.semibold)).foregroundStyle(Color.tpReferenceBlue)
            } else {
                Picker(language.text("방향", "Direction"), selection: Binding(get: { isReturning }, set: { if $0 != isReturning { swap() } })) {
                    Text(language.text("출국편", "Outbound")).tag(false)
                    Text(language.text("귀국편", "Return")).tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("flightDirection")
            }
            FlightDateStrip(language: language, days: stripDays, selected: $day, marked: [trip.startDay, trip.endDay])
            TextField(language.text("편명으로 좁히기(선택)", "Filter by flight number (optional)"), text: $flightQuery)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
        } header: {
            Text(language.text("조회", "Search"))
        } footer: {
            Text(language.text("공항 코드·날짜·방향·편명만 서버로 보냅니다. 예약번호·이름은 보내지 않습니다.", "Only the airport code, date, direction and flight number are sent. Booking numbers and names are never sent."))
        }
        .accessibilityIdentifier("flightSearchCard")
    }

    private func airportButton(_ airport: FlightPlacement.AirportChoice?, side which: Side, id: String, placeholder: String) -> some View {
        Button { side = which } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(airport?.code ?? "---").font(.title2.monospaced().weight(.bold))
                Text(airport.map { language.runtimeText($0.nameKo, $0.nameEn) } ?? placeholder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .overlay(RoundedRectangle(cornerRadius: TaptionCorner.small).stroke(Color.tpReferenceGray.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: 결과

    @ViewBuilder
    private var resultSection: some View {
        Section {
            if let found {
                HStack {
                    Picker(language.text("정렬", "Sort"), selection: $sort) {
                        Text(language.text("출발 빠른 순", "Earliest departure")).tag(FlightSearch.Sort.departure)
                        Text(language.text("도착 빠른 순", "Earliest arrival")).tag(FlightSearch.Sort.arrival)
                        Text(language.text("소요 짧은 순", "Shortest")).tag(FlightSearch.Sort.duration)
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("flightSort")
                    Spacer()
                    Toggle(language.text("직항만", "Direct only"), isOn: Binding(
                        get: { directOnly },
                        set: { if isDomestic { directOnlyDomestic = $0 } else { directOnlyInternational = $0 } }
                    ))
                    .fixedSize()
                    .accessibilityIdentifier("flightDirectOnly")
                }
                if rows.isEmpty {
                    Text(language.text("이 조건에 맞는 편이 없어요. 날짜나 공항을 바꿔 보세요.", "No flights match. Try another date or airport.")).foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    Button { Task { await add(row) } } label: { FlightResultRow(language: language, row: row) }
                        .buttonStyle(.plain)
                        .disabled(isSaving)
                }
                if found.excludedCodeshare > 0 {
                    Text(language.runtimeText("직항 \(found.rows.count)편 · 공동운항 \(found.excludedCodeshare)편 제외", "\(found.rows.count) direct · \(found.excludedCodeshare) codeshare hidden"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if isLoading {
                ForEach(0..<4, id: \.self) { _ in skeletonRow }
            } else if let failure {
                Text(message(for: failure)).font(.callout).foregroundStyle(.secondary)
                Button(language.text("다시 시도", "Try again")) { Task { await load() } }
            } else if to == nil && !isDomestic && !fromIsKorean {
                Text(language.text("도착할 공항을 골라 주세요.", "Pick an arrival airport.")).foregroundStyle(.secondary)
            }
        } header: {
            if isLoading && found != nil { HStack { Text(sourceTitle); ProgressView() } } else { Text(sourceTitle) }
        }
    }

    private var skeletonRow: some View {
        RoundedRectangle(cornerRadius: TaptionCorner.small).fill(Color.tpReferenceGray.opacity(0.15)).frame(height: 54)
            .accessibilityHidden(true)
    }

    // MARK: 알림 붙여넣기

    /// 항공사 알림톡·문자를 복사해 와서 붙이면 읽어 카드에 붙인다. 시스템 붙여넣기 단추만 쓰고 클립보드를 직접 읽지 않는다.
    private var pasteSection: some View {
        Section {
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in
                    let reply = await model.ingestFlightAlert(text, source: .paste)
                    // 읽지 못한 글만 이 화면에 남고, 나머지는 홈 위쪽에서 결과를 보여 주거나 어느 카드인지 묻는다.
                    if case .unreadable = reply { pasteUnreadable = true; return }
                    pasteUnreadable = false
                    FlightAlertCenter.shared.show(reply)
                    dismiss()
                }
            }
            .accessibilityIdentifier("flightPasteAlert")
            if pasteUnreadable {
                Text(language.text("항공편 알림으로 읽지 못했어요.", "Could not read this as a flight notice.")).font(.callout).foregroundStyle(.orange)
            }
        } header: {
            Text(language.text("항공사 알림 붙여넣기", "Paste an airline notice"))
        } footer: {
            Text(language.text("항공사 문자나 알림톡을 복사한 뒤 붙이면 읽어서 이 여행의 항공편 카드에 붙입니다. 이름·예약번호는 이 기기 안에서만 쓰고 보내지 않습니다.", "Copy an airline text or notice, then paste it: it is read and attached to this trip's flight card. Names and booking numbers stay on this device and are never sent."))
        }
    }

    // MARK: 직접 넣기

    private var manualSection: some View {
        Section {
            TextField(language.text("편명(예: AB123)", "Flight number (e.g. AB123)"), text: $manualFlight)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            DatePicker(language.text("출발 시각", "Departure time"), selection: $manualTime, displayedComponents: .hourAndMinute)
                .environment(\.calendar, calendar)
                .environment(\.timeZone, .gmt)
            TextField(language.text("비행 시간(분, 비우면 거리로 어림)", "Flight minutes (empty = estimate)"), text: $manualDuration)
                .keyboardType(.numberPad)
            Button(language.text("직접 넣기", "Add manually")) { Task { await addManual() } }
                .disabled(isSaving || to == nil)
                .accessibilityIdentifier("flightAddManual")
            if let url = FlightLookup.searchURL(for: manualFlight) {
                Link(language.text("편명으로 검색", "Search the flight number"), destination: url)
            }
        } header: {
            Text(language.text("직접 넣기", "Add manually"))
        } footer: {
            Text(language.text("행선지를 위에서 고른 뒤 시각을 적으면 그 공항의 현지 시각으로 넣습니다. 도착 시각은 비행 시간이나 거리로 어림합니다.", "Pick the other airport above, then enter the local time. The arrival is computed from the flight time or estimated from the distance."))
        }
    }

    private var sourceTitle: String {
        sourceIsLive && !isDomestic ? language.text("실시간 운항 반영", "With live status") : language.text("정기 스케줄 기준", "Scheduled timetable")
    }

    private func message(for failure: FlightLookup.Failure) -> String {
        switch failure {
        case .routeMissing: language.text("조회 서버에 항공편 경로가 아직 없어요. 직접 넣거나 편명으로 검색해 보세요.", "The lookup server has no flight route yet. Add it manually or search the flight number.")
        case .keyMissing: language.text("항공편 조회 키가 아직 등록되지 않았어요. 직접 넣거나 편명으로 검색해 보세요.", "The flight lookup key is not registered yet. Add it manually or search the flight number.")
        case .noServer: language.text("중계 서버 주소가 없어 조회할 수 없어요. 직접 넣거나 편명으로 검색해 보세요.", "No relay server address, so it can't be looked up. Add it manually or search the flight number.")
        case .outOfRange: language.text("이 날짜는 조회할 수 없어요. 직접 넣거나 편명으로 검색해 보세요.", "This date can't be looked up. Add it manually or search the flight number.")
        case .limited: language.text("오늘 조회 한도에 도달했어요. 직접 넣거나 편명으로 검색해 보세요.", "Today's lookup limit is reached. Add it manually or search the flight number.")
        default: language.text("시간표를 불러오지 못했어요. 직접 넣거나 편명으로 검색해 보세요.", "Could not load the timetable. Add it manually or search the flight number.")
        }
    }

    // MARK: 동작

    /// 출국편은 여행 첫날, 귀국편은 마지막 날로 시작한다.
    private func applyDefaultDay() {
        day = FlightPlacement.defaultDay(for: trip, returning: isReturning)
            ?? TravelTripDay.string(for: .now, offsetSeconds: TimeZone.current.secondsFromGMT())
    }

    private func swap() {
        let previous = from
        if let to { from = to; self.to = previous } else { to = previous; from = FlightPlacement.AirportChoice(code: "ICN", nameKo: "인천", nameEn: "Incheon") }
        found = nil; failure = nil
    }

    private func pick(_ airport: FlightPlacement.AirportChoice, side which: Side) {
        let incheon = FlightPlacement.AirportChoice(code: "ICN", nameKo: "인천", nameEn: "Incheon")
        switch which {
        case .from:
            from = airport
            if to?.code == airport.code { to = nil }
            if !FlightSearch.isKorean(airport.code), let other = to, !FlightSearch.isKorean(other.code) { to = incheon }
        case .to:
            to = airport
            if from.code == airport.code { from = incheon }
            if !FlightSearch.isKorean(airport.code), !FlightSearch.isKorean(from.code) { from = incheon }
        }
        found = nil; failure = nil
    }

    private func load() async {
        // 국제선은 한국 쪽 공항만으로 조회한다. 국내선은 도착 공항이 있어야 한다.
        if !isDomestic, !fromIsKorean, to == nil { return }
        if FlightSearch.isKorean(from.code), let to, FlightSearch.isKorean(to.code), !isDomestic { return } // 인천↔국내는 국내선이 아니다
        loadToken += 1
        let token = loadToken
        isLoading = true
        didFail = false
        defer { if token == loadToken { isLoading = false } }
        let dayKey = day
        if isDomestic, let to {
            async let dep = FlightLookup.fetch(.schedule, airport: from.code, day: dayKey, direction: .dep)
            async let arr = FlightLookup.fetch(.schedule, airport: to.code, day: dayKey, direction: .arr)
            let (first, second) = await (dep, arr)
            guard token == loadToken else { return }
            var depRows: [FlightListing] = [], arrRows: [FlightListing] = []
            if case .found(let value) = first { depRows = value.flights }
            if case .found(let value) = second { arrRows = value.flights }
            if case .unavailable(let reason) = first, case .unavailable = second { found = nil; failure = reason; return }
            found = FlightSearch.domestic(dep: depRows, arr: arrRows, origin: from.code, destination: to.code)
            failure = nil
            return
        }
        async let schedule = FlightLookup.fetch(.schedule, airport: koreanCode, day: dayKey, direction: direction)
        async let status = FlightLookup.fetch(.status, airport: koreanCode, day: dayKey, direction: direction)
        let (first, second) = await (schedule, status)
        guard token == loadToken else { return }
        var scheduleResult: FlightListResult?
        var statusResult: FlightListResult?
        if case .found(let value) = first { scheduleResult = value }
        if case .found(let value) = second { statusResult = value }
        if let merged = FlightLookup.merged(schedule: scheduleResult, status: statusResult) {
            found = FlightSearch.international(merged.flights, direction: direction)
            failure = nil
            sourceIsLive = merged.source == .status
        } else {
            found = nil
            failure = { if case .unavailable(let reason) = first { return reason }; return .failed }()
        }
    }

    private func add(_ row: FlightSearch.Row) async {
        guard let draft = FlightPlacement.draft(from: row, day: day) else { didFail = true; return }
        await save(draft)
    }

    private func addManual() async {
        guard let to else { return }
        let parts = calendar.dateComponents([.hour, .minute], from: manualTime)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        guard let draft = FlightPlacement.manualDraft(
            flight: manualFlight, origin: from.code, destination: to.code, day: day, minute: minute, durationMinutes: Int(manualDuration.filter(\.isNumber))
        ) else { didFail = true; return }
        await save(draft)
    }

    private func save(_ draft: FlightPlacement.Draft) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let id = await TripSharePlanEditor.addItem(
            model: model, tripID: trip.id, kind: .flight, title: draft.title, start: draft.start, end: draft.end,
            offsetSeconds: draft.startOffsetSeconds, endOffsetSeconds: draft.endOffsetSeconds, place: draft.arrivalPlace, flight: draft.fields
        )
        didFail = id == nil
        if let id {
            await model.syncFlightBriefings()
            onAdded(id)
            dismiss()
        }
    }
}
