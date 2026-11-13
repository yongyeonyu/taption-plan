import SwiftUI
import TaptionPlanStore

/// 새 여행 만들기: 이름·기간·여행지. 당일치기와 지난 날짜도 된다.
struct TravelNewTripSheet: View {
    struct Draft: Identifiable {
        let id = UUID()
        var isDayTrip: Bool
        /// 고칠 여행. 없으면 새로 만든다.
        var editing: TravelTrip?
    }

    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let draft: Draft
    let onCreate: (TravelTrip) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var isDayTrip = false
    /// 날짜는 나중에 정하는 여행(버킷리스트).
    @State private var isWish = false
    @State private var wishNights = 3
    @State private var start = Date.now
    @State private var end = Date.now
    @State private var countryCode = "KR"
    @State private var provinceCode = ""
    @State private var isSaving = false

    private var countries: [TravelGlobeRegion] {
        TravelModeRegions.countries.filter { $0.code.count == 2 }.sorted { name($0) < name($1) }
    }

    private func name(_ region: TravelGlobeRegion) -> String {
        language == .korean && !region.nameKo.isEmpty ? region.nameKo : region.nameEn
    }

    private var currency: String? {
        countryCode == "KR" ? nil : TravelModeRegions.currency(forCountry: countryCode)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(language.text("여행 이름", "Trip name"), text: $title)
                    Toggle(language.text("언젠가 갈 여행 (날짜는 나중에)", "Someday trip (dates later)"), isOn: $isWish)
                    if isWish {
                        Stepper(value: $wishNights, in: 0...60) {
                            Text(wishNights == 0 ? language.text("당일", "Day trip") : language.runtimeText("\(wishNights)박 \(wishNights + 1)일", "\(wishNights) nights, \(wishNights + 1) days"))
                        }
                    } else {
                        Toggle(language.text("당일치기", "Day trip"), isOn: $isDayTrip)
                        DatePicker(isDayTrip ? language.text("날짜", "Date") : language.text("첫날", "First day"), selection: $start, displayedComponents: .date)
                        if !isDayTrip {
                            DatePicker(language.text("마지막 날", "Last day"), selection: $end, in: start..., displayedComponents: .date)
                        }
                    }
                } footer: {
                    Text(isWish
                         ? language.text("버킷리스트에 담아 둡니다. 날짜를 정하면 일정을 넣을 수 있습니다.", "Saved to your bucket list. Set dates later to add plans.")
                         : language.text("지난 날짜로 만들면 그날의 기록이 이 여행의 실제 기록이 됩니다.", "A past date turns that day's records into this trip's actual records."))
                }
                Section(language.text("여행지", "Destination")) {
                    Picker(language.text("나라", "Country"), selection: $countryCode) {
                        ForEach(countries) { Text(name($0)).tag($0.code) }
                    }
                    if countryCode == "KR" {
                        Picker(language.text("지역", "Region"), selection: $provinceCode) {
                            Text(language.text("정하지 않음", "Not set")).tag("")
                            ForEach(TravelModeRegions.provinces) { Text(name($0)).tag($0.code) }
                        }
                    }
                    LabeledContent(language.text("여행지 통화", "Trip currency"), value: currency ?? language.text("원화만", "Home currency only"))
                }
            }
            .navigationTitle(draft.editing == nil ? language.text("새 여행", "New trip") : language.text("여행 고치기", "Edit trip"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(language.text("취소", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.editing == nil ? language.text("만들기", "Create") : language.text("저장", "Save")) { Task { await create() } }.disabled(isSaving)
                }
            }
            .onAppear(perform: prepare)
            .onChange(of: start) { _, value in if end < value { end = value } }
        }
        // 지구본 화면이 어두워도 이 시트는 밝게: 어두운 바탕에서 「취소」·「만들기」 글자가 묻혔다.
        .preferredColorScheme(.light)
    }

    /// 고칠 때는 그 여행의 값으로 채운다.
    private func prepare() {
        isDayTrip = draft.isDayTrip
        guard let trip = draft.editing else { return }
        title = trip.title
        isWish = trip.isWish
        wishNights = max(0, (trip.wishDays ?? 4) - 1)
        let calendar = Calendar.autoupdatingCurrent
        if let first = TravelTripDay.components(trip.startDay).flatMap(calendar.date(from:)) { start = first }
        if let last = TravelTripDay.components(trip.endDay).flatMap(calendar.date(from:)) { end = last }
        countryCode = trip.countryCode ?? "KR"
        provinceCode = TravelModeRegions.provinces.first { $0.nameKo == trip.regionName }?.code ?? ""
    }

    private func day(_ date: Date) -> String {
        let parts = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: date)
        return TravelTripDay.string(year: parts.year ?? 0, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    private func create() async {
        isSaving = true
        defer { isSaving = false }
        let country = TravelModeRegions.countries.first { $0.code == countryCode }
        let province = TravelModeRegions.provinces.first { $0.code == provinceCode && countryCode == "KR" }
        let place = province ?? country
        // 깃발 자리: 나라만 고르면 대표 공항, 시·도면 그 땅 위(TFP1114A01: 네모 가운데를 저장해 바다에 꽂혔음).
        let flagPoint = province.map(TravelModeRegions.landAnchor) ?? country.map(TravelModeRegions.flagPoint)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = draft.editing
        // 나라·지역을 바꾸지 않았으면 전에 잡아 둔 자리·통화를 그대로 둔다.
        let samePlace = old != nil && old?.countryCode == country?.code && old?.regionName == province?.nameKo
        var trip = TravelTrip(
            id: old?.id ?? "trip-\(UUID().uuidString.lowercased())",
            title: trimmed.isEmpty ? (place.map(name) ?? "") : trimmed,
            startDay: isWish ? "" : day(start), endDay: isWish ? "" : day(isDayTrip ? start : max(start, end)),
            countryCode: country?.code, regionName: province?.nameKo,
            latitude: flagPoint?.y, longitude: flagPoint?.x, currencyCode: currency, wishDays: isWish ? wishNights + 1 : nil
        )
        if let old {
            trip.flagColorHex = old.flagColorHex
            trip.columns = old.columns
            trip.timeZoneID = old.timeZoneID
            if samePlace {
                trip.latitude = old.latitude
                trip.longitude = old.longitude
                trip.currencyCode = old.currencyCode
            }
        }
        guard await model.saveTravelTrip(trip) else { return }
        // 첫날을 옮겼으면 넣어 둔 일정 전체를 같은 날 수만큼 함께 옮긴다. 언젠가 여행은 1일차 기준일에서 옮긴다(WPS1114A01).
        if let old, let moved = TravelTripDay.days(from: old.planStartDay, to: trip.planStartDay), moved != 0 {
            await model.shiftTravelTrip(trip.id, byDays: moved)
        }
        dismiss()
        onCreate(trip)
    }
}

/// 계획표 열 편집(TVU1113A01, Trip 원본의 분류 관리): 열의 이름·순서·개수(2~6)와, 종류 12가지를 어느 열에 놓을지.
struct TravelColumnEditorSheet: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let trip: TravelTrip

    @Environment(\.dismiss) private var dismiss
    @State private var columns: [TravelTripColumn] = []
    @State private var isSaving = false

    private func title(_ index: Int) -> String { TravelPlanTable.title(columns[index], index: index, language: language) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(columns.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 2) {
                            TextField(title(index), text: Binding(get: { columns[index].name }, set: { columns[index].name = $0 }))
                                .accessibilityIdentifier("travelColumnName-\(index)")
                            Text(columns[index].kinds.compactMap { TripImportItem.Kind(rawValue: $0)?.planName }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .onMove { columns.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { offsets in for index in offsets.sorted(by: >) { columns = TravelPlanColumns.removing(index, from: columns) } }
                    .deleteDisabled(columns.count <= TravelPlanColumns.countRange.lowerBound)
                    Button(language.text("열 더하기", "Add column"), systemImage: "plus") { columns.append(TravelTripColumn(name: "", kinds: [])) }
                        .disabled(columns.count >= TravelPlanColumns.countRange.upperBound)
                        .accessibilityIdentifier("travelColumnAdd")
                } header: {
                    Text(language.text("열", "Columns"))
                } footer: {
                    Text(language.text("이름을 비우면 기본 이름을 씁니다. 열을 지우면 그 종류는 옆 열로 옮겨집니다.", "Leave a name empty to use the default. Deleting a column moves its kinds to the next one."))
                }
                Section(language.text("종류를 놓을 열", "Column for each kind")) {
                    ForEach(TravelPlanColumns.allKinds, id: \.self) { kind in
                        Picker(TripImportItem.Kind(rawValue: kind)?.planName ?? kind, selection: Binding(
                            get: { TravelPlanColumns.index(forKind: kind, in: columns) },
                            set: { columns = TravelPlanColumns.moving(kind: kind, to: $0, in: columns) }
                        )) {
                            ForEach(columns.indices, id: \.self) { Text(title($0)).tag($0) }
                        }
                    }
                }
                Section {
                    Button(language.text("기본 열로", "Reset to default columns")) { columns = TravelPlanColumns.defaults }
                        .accessibilityIdentifier("travelColumnReset")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(language.text("열 편집", "Edit columns"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(language.text("취소", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(language.text("저장", "Save")) { Task { await save() } }.disabled(isSaving) }
            }
            .onAppear { if columns.isEmpty { columns = TravelPlanColumns.resolved(trip.columns) } }
        }
        .preferredColorScheme(.light)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        // 그사이 다른 곳에서 고친 여행 속성을 덮지 않게 지금 저장된 여행에 열만 바꿔 넣는다.
        var next = model.settings.travelTrips?.first { $0.id == trip.id } ?? trip
        next.columns = TravelPlanColumns.stored(columns)
        if await model.saveTravelTrip(next) { dismiss() }
    }
}
