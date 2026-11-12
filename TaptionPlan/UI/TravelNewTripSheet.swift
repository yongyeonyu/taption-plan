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
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = draft.editing
        // 나라·지역을 바꾸지 않았으면 전에 잡아 둔 자리·통화를 그대로 둔다.
        let samePlace = old != nil && old?.countryCode == country?.code && old?.regionName == province?.nameKo
        var trip = TravelTrip(
            id: old?.id ?? "trip-\(UUID().uuidString.lowercased())",
            title: trimmed.isEmpty ? (place.map(name) ?? "") : trimmed,
            startDay: isWish ? "" : day(start), endDay: isWish ? "" : day(isDayTrip ? start : max(start, end)),
            countryCode: country?.code, regionName: province?.nameKo,
            latitude: place?.anchor.y, longitude: place?.anchor.x, currencyCode: currency, wishDays: isWish ? wishNights + 1 : nil
        )
        if let old {
            trip.flagColorHex = old.flagColorHex
            trip.timeZoneID = old.timeZoneID
            if samePlace {
                trip.latitude = old.latitude
                trip.longitude = old.longitude
                trip.currencyCode = old.currencyCode
            }
        }
        guard await model.saveTravelTrip(trip) else { return }
        dismiss()
        onCreate(trip)
    }
}
