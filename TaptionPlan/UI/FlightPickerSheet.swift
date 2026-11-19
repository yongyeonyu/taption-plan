import SwiftUI
import TaptionPlanStore

/// 항공편 고르기(FLT1119A01). 한국 공항의 그날 출발·도착 편을 서버(공공데이터)에서 받아 목록으로 보여 주고, 고르면 여행 일정에 비행 칸으로 넣는다.
/// 서버로는 공항 코드·날짜·방향·편명만 보낸다. 서버 주소가 없거나 키·한도·네트워크로 못 받아도 오류 화면 없이 「직접 넣기」와 「편명으로 검색」이 남는다.
struct FlightPickerSheet: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let trip: TravelTrip
    /// 넣은 일정 번호를 알린다(되돌리기 기록용).
    var onAdded: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var isReturning = false
    @State private var koreanAirport = "ICN"
    @State private var otherQuery = ""
    @State private var other: FlightPlacement.AirportChoice?
    @State private var flightQuery = ""
    @State private var date = Date()
    @State private var result: FlightListResult?
    @State private var failure: FlightLookup.Failure?
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var isSaving = false
    @State private var didFail = false
    @State private var manualFlight = ""
    @State private var manualTime = Date(timeIntervalSince1970: 9 * 3_600)
    @State private var manualDuration = ""

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    /// 고른 날(그 공항 달력의 날).
    private var dayKey: String { TravelTripDay.string(for: date, offsetSeconds: 0) }
    private var direction: FlightLookup.Direction { isReturning ? .arr : .dep }

    private var rows: [FlightListing] {
        let flights = result?.flights ?? []
        let query = flightQuery.replacingOccurrences(of: " ", with: "").uppercased()
        return flights.filter { row in
            if let other, (isReturning ? row.origin : row.destination) != other.code { return false }
            return query.isEmpty || row.flight.contains(query)
        }
    }

    private var airportMatches: [FlightPlacement.AirportChoice] {
        let text = otherQuery.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, other?.nameKo != text, other?.code != text.uppercased() else { return [] }
        return FlightPlacement.searchAirports(text, limit: 5)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(language.text("방향", "Direction"), selection: $isReturning) {
                        Text(language.text("출국편(한국에서 출발)", "Outbound (leaving Korea)")).tag(false)
                        Text(language.text("귀국편(한국에 도착)", "Return (arriving in Korea)")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("flightDirection")
                    Picker(language.text("한국 공항", "Korean airport"), selection: $koreanAirport) {
                        ForEach(FlightPlacement.koreanAirports) { Text("\($0.nameKo) \($0.code)").tag($0.code) }
                    }
                    DatePicker(language.text("날짜", "Date"), selection: $date, displayedComponents: .date)
                        .environment(\.calendar, calendar)
                        .environment(\.timeZone, .gmt)
                    TextField(isReturning ? language.text("출발한 도시·공항 코드", "City or airport code you fly from") : language.text("도착할 도시·공항 코드", "City or airport code you fly to"), text: $otherQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("flightOtherAirport")
                    ForEach(airportMatches, id: \.code) { airport in
                        Button {
                            other = airport
                            otherQuery = airport.nameKo
                        } label: {
                            HStack {
                                Text(language.runtimeText(airport.nameKo, airport.nameEn))
                                Spacer()
                                Text(airport.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    TextField(language.text("편명으로 좁히기(선택)", "Filter by flight number (optional)"), text: $flightQuery)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button { Task { await load() } } label: {
                        HStack {
                            Label(language.text("시간표 불러오기", "Load timetable"), systemImage: "airplane")
                            if isLoading { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isLoading)
                    .accessibilityIdentifier("flightLoad")
                } header: {
                    Text(language.text("조회", "Search"))
                } footer: {
                    Text(language.text("공항 코드·날짜·방향·편명만 서버로 보냅니다. 예약번호·이름은 보내지 않습니다.", "Only the airport code, date, direction and flight number are sent. Booking numbers and names are never sent."))
                }

                if let failure, result == nil {
                    Section { Text(message(for: failure)).font(.callout).foregroundStyle(.secondary) }
                }

                if hasLoaded, result != nil {
                    Section {
                        if rows.isEmpty {
                            Text(language.text("이 조건에 맞는 편이 없어요. 날짜나 공항을 바꿔 보세요.", "No flights match. Try another date or airport.")).foregroundStyle(.secondary)
                        }
                        ForEach(rows) { row in
                            Button { Task { await add(row) } } label: { rowLabel(row) }
                                .disabled(isSaving)
                        }
                    } header: {
                        Text(sourceTitle)
                    } footer: {
                        if let updated = result?.updatedAt {
                            Text(language.runtimeText("갱신 \(updated.formatted(date: .omitted, time: .shortened))", "Updated \(updated.formatted(date: .omitted, time: .shortened))"))
                        }
                    }
                }

                manualSection

                if didFail {
                    Section { Text(language.text("일정에 넣지 못했어요. 시각이나 공항을 확인해 주세요.", "Could not add it. Check the time and airports.")).foregroundStyle(.red) }
                }
            }
            .navigationTitle(language.text("항공편 찾기", "Find a flight"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(language.text("닫기", "Close")) { dismiss() } } }
            .onAppear(perform: applyDefaultDay)
            .onChange(of: isReturning) { _, _ in
                applyDefaultDay()
                result = nil
                hasLoaded = false
            }
        }
        .accessibilityIdentifier("flightPickerSheet")
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
                .disabled(isSaving || other == nil)
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

    // MARK: 행

    private func rowLabel(_ row: FlightListing) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(row.time).font(.body.monospacedDigit().weight(.semibold))
                Text(row.flight).font(.body.monospaced())
                Text("\(row.origin) → \(row.destination)").foregroundStyle(.secondary)
                Spacer()
                if row.status != nil { badge(language.text("실시간", "Live")) } else { badge(language.text("정기", "Scheduled")) }
            }
            HStack(spacing: 8) {
                if let terminal = row.status?.terminal ?? row.terminal { Text(language.runtimeText("터미널 \(terminal)", "Terminal \(terminal)")) }
                if let gate = row.status?.gate ?? row.gate { Text(language.runtimeText("탑승구 \(gate)", "Gate \(gate)")) }
                if let status = row.status, status.isProblem { Text(stateText(status)).foregroundStyle(.orange) }
                if row.codeshare { Text(language.text("공동운항", "Codeshare")) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }

    private func stateText(_ status: FlightLiveStatus) -> String {
        status.state == "cancelled"
            ? language.text("결항", "Cancelled")
            : language.runtimeText("\(status.delayMinutes)분 지연", "Delayed \(status.delayMinutes) min")
    }

    private var sourceTitle: String {
        result?.source == .status ? language.text("실시간 운항 반영", "With live status") : language.text("정기 스케줄 기준", "Scheduled timetable")
    }

    private func message(for failure: FlightLookup.Failure) -> String {
        switch failure {
        case .outOfRange: language.text("이 날짜는 조회할 수 없어요. 직접 넣거나 편명으로 검색해 보세요.", "This date can't be looked up. Add it manually or search the flight number.")
        case .limited: language.text("오늘 조회 한도에 도달했어요. 직접 넣거나 편명으로 검색해 보세요.", "Today's lookup limit is reached. Add it manually or search the flight number.")
        default: language.text("시간표를 불러오지 못했어요. 직접 넣거나 편명으로 검색해 보세요.", "Could not load the timetable. Add it manually or search the flight number.")
        }
    }

    // MARK: 동작

    /// 출국편은 여행 첫날, 귀국편은 마지막 날로 시작한다.
    private func applyDefaultDay() {
        guard let day = FlightPlacement.defaultDay(for: trip, returning: isReturning), let parts = TravelTripDay.components(day),
              let value = calendar.date(from: parts) else { return }
        date = value
    }

    private func load() async {
        isLoading = true
        didFail = false
        defer { isLoading = false }
        async let schedule = FlightLookup.fetch(.schedule, airport: koreanAirport, day: dayKey, direction: direction)
        async let status = FlightLookup.fetch(.status, airport: koreanAirport, day: dayKey, direction: direction)
        let (first, second) = await (schedule, status)
        var scheduleResult: FlightListResult?
        var statusResult: FlightListResult?
        if case .found(let value) = first { scheduleResult = value }
        if case .found(let value) = second { statusResult = value }
        result = FlightLookup.merged(schedule: scheduleResult, status: statusResult)
        failure = result == nil ? { if case .unavailable(let reason) = first { return reason }; return .failed }() : nil
        hasLoaded = true
    }

    private func add(_ row: FlightListing) async {
        guard let draft = FlightPlacement.draft(from: row, day: dayKey, direction: direction) else { didFail = true; return }
        await save(draft)
    }

    private func addManual() async {
        guard let other else { return }
        let parts = calendar.dateComponents([.hour, .minute], from: manualTime)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let origin = isReturning ? other.code : koreanAirport, destination = isReturning ? koreanAirport : other.code
        guard let draft = FlightPlacement.manualDraft(
            flight: manualFlight, origin: origin, destination: destination, day: dayKey, minute: minute, durationMinutes: Int(manualDuration.filter(\.isNumber))
        ) else { didFail = true; return }
        await save(draft)
    }

    private func save(_ draft: FlightPlacement.Draft) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let id = await TripSharePlanEditor.addItem(
            model: model, tripID: trip.id, kind: .flight, title: draft.title, start: draft.start, end: draft.end,
            offsetSeconds: draft.startOffsetSeconds, endOffsetSeconds: draft.endOffsetSeconds, flight: draft.fields
        )
        didFail = id == nil
        if let id {
            onAdded(id)
            dismiss()
        }
    }
}
