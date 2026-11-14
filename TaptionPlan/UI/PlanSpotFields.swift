import CoreLocation
import MapKit
import SwiftUI
import TaptionPlanCore

/// 일정에 붙이는 선택 칸(PLB1114A18): 장소와 예상 지출. 저장할 수 있는 값만 남긴다.
struct PlanSpot: Equatable {
    private(set) var place: PlanPlace?
    private(set) var plannedSpendKRW: Double?

    init(place: PlanPlace?, plannedSpendKRW: Double?) {
        self.place = place.flatMap { place in
            let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, place.latitude.isFinite, place.longitude.isFinite,
                  CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)) else { return nil }
            return PlanPlace(name: name, latitude: place.latitude, longitude: place.longitude)
        }
        self.plannedSpendKRW = plannedSpendKRW.flatMap { $0.isFinite && $0 >= 1 ? $0.rounded() : nil }
    }

    /// 입력 칸의 글(숫자만 읽는다)로 만든다.
    init(place: PlanPlace?, spendText: String) {
        self.init(place: place, plannedSpendKRW: Double(TravelQuickEntrySheet.spendDigits(spendText)))
    }

    /// 「계획과 실제」 지도에 그릴 그날 일반 일정의 장소. 이미 여행 핀이 이어진 일정·루틴·건너뛴 일정은 뺀다. 저장하지 않는 값이다.
    static func mapStops(plans: [PlanRecord], day: TimeSpan, pinned: Set<UUID>, after order: Int) -> [TravelPlanStop] {
        plans.filter { $0.place != nil && $0.status != .skipped && !pinned.contains($0.id) && !GoalRecordPolicy.isGoal($0) && $0.span.intersection(with: day) != nil }
            .sorted { ($0.span.start, $0.id.uuidString) < ($1.span.start, $1.id.uuidString) }
            .enumerated().compactMap { index, plan in
                plan.place.map {
                    TravelPlanStop(id: plan.id, title: $0.name, latitude: $0.latitude, longitude: $0.longitude, day: day.start, order: order + index, planID: plan.id)
                }
            }
    }
}

/// 일정 더하기·고치기 시트의 「장소」「예상 지출」 줄. 둘 다 비워 둘 수 있다.
struct PlanSpotFields: View {
    @Bindable var model: AppModel
    @Binding var place: PlanPlace?
    @Binding var spendText: String
    var language = MapHomeLanguage.current

    @State private var showsPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.regular) {
            HStack(spacing: TaptionSpacing.snug) {
                Label(language.text("장소", "Place"), systemImage: "mappin.and.ellipse")
                    .font(.taption(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Spacer(minLength: 8)
                Button { showsPicker = true } label: {
                    Text(verbatim: place?.name ?? language.text("장소 고르기", "Choose a place"))
                        .font(.taption(size: 10.5, weight: .semibold))
                        .foregroundStyle(place == nil ? Color.tpSecondary : Color.tpInk)
                        .lineLimit(1)
                        .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("planSpotPlace")
                if place != nil {
                    Button { place = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.tpSecondary.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(language.text("장소 지우기", "Remove place"))
                }
            }
            HStack(spacing: TaptionSpacing.snug) {
                Label(language.text("예상 지출", "Planned spend"), systemImage: "wonsign.circle")
                    .font(.taption(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                TextField("0", text: $spendText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.taption(size: 11.5, weight: .semibold).monospacedDigit())
                    .onChange(of: spendText) { _, value in
                        let digits = TravelQuickEntrySheet.spendDigits(value)
                        if digits != value { spendText = digits }
                    }
                    .accessibilityLabel(language.text("예상 지출", "Planned spend"))
                    .accessibilityIdentifier("planSpotSpend")
            }
            Text(language.text(
                "장소에 도착하면 메모와 예상 지출을 보여 주고, 「계획과 실제」에서 견줍니다.",
                "Shows your note and planned spend on arrival, and compares them in Plan vs actual."
            ))
            .font(.taption(size: 8.5, weight: .semibold))
            .foregroundStyle(Color.tpSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.tpFieldFill, in: RoundedRectangle(cornerRadius: TaptionRadius.field))
        .sheet(isPresented: $showsPicker) {
            PlanPlacePicker(language: language, saved: model.settings.frequentPlaces, center: center) { picked in
                if place != picked { place = picked }
            }
        }
    }

    /// 찾기의 가운데: 앱이 마지막으로 받은 위치, 없으면 좌표가 있는 첫 등록 지점.
    private var center: CLLocationCoordinate2D? {
        (model.latestSensorReading?.point ?? model.settings.frequentPlaces.lazy.compactMap(\.point).first)
            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }
}

/// 일정의 장소 고르기. 등록 지점을 먼저 보이고(대표 결정), 그 아래에 이름으로 찾은 곳을 둔다.
/// 국내는 카카오 결과도 보이지만 좌표는 저장하지 않고 Apple 지도에서 다시 받는다.
struct PlanPlacePicker: View {
    let language: MapHomeLanguage
    let saved: [FrequentPlace]
    let center: CLLocationCoordinate2D?
    let onPick: (PlanPlace) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var results: [MapHomeSearchResult] = []
    @State private var isSearching = false
    @State private var didSearch = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField(language.text("장소 이름", "Place name"), text: $text)
                            .submitLabel(.search)
                            .onSubmit { Task { await search() } }
                            .accessibilityIdentifier("planPlaceQuery")
                        if isSearching { ProgressView() }
                    }
                }
                let registered = Self.registered(saved, matching: text)
                if !registered.isEmpty {
                    Section(language.text("등록한 장소", "Saved place")) {
                        ForEach(registered, id: \.self) { place in
                            Button { choose(place) } label: { Label { Text(verbatim: place.name) } icon: { Image(systemName: "star") } }
                        }
                    }
                }
                Section {
                    ForEach(results) { result in
                        Button { Task { await pick(result) } } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: result.title)
                                if !result.subtitle.isEmpty {
                                    Text(verbatim: result.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                    if let notice {
                        Text(verbatim: notice).font(.footnote).foregroundStyle(.secondary)
                    } else if didSearch, results.isEmpty, !isSearching {
                        Text(language.text("찾은 곳이 없습니다. 다른 이름으로 찾아 보세요.", "Nothing found. Try another name.")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .foregroundStyle(Color.tpInk)
            .navigationTitle(language.text("장소 고르기", "Choose a place"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(language.text("취소", "Cancel")) { dismiss() } } }
        }
    }

    /// 좌표가 있는 등록 지점. 찾을 말이 있으면 이름에 그 말이 든 것만.
    static func registered(_ saved: [FrequentPlace], matching text: String) -> [PlanPlace] {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.compactMap { place in
            guard let point = place.point, wanted.isEmpty || place.displayName.localizedCaseInsensitiveContains(wanted) else { return nil }
            return PlanSpot(place: PlanPlace(name: place.displayName, latitude: point.latitude, longitude: point.longitude), plannedSpendKRW: nil).place
        }
    }

    private func choose(_ place: PlanPlace) {
        onPick(place)
        dismiss()
    }

    private func search() async {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return }
        isSearching = true
        notice = nil
        defer {
            isSearching = false
            didSearch = true
        }
        var found = center == nil ? [] : await MapHomeKakaoSearch.search(query: wanted, center: center ?? CLLocationCoordinate2D())
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = wanted
        if let center { request.region = MKCoordinateRegion(center: center, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
        let items = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
        found += items.prefix(15).map {
            MapHomeSearchResult(title: $0.name ?? wanted, subtitle: $0.placemark.title ?? "", coordinate: $0.placemark.coordinate)
        }
        results = found
    }

    private func pick(_ result: MapHomeSearchResult) async {
        var coordinate: CLLocationCoordinate2D? = result.coordinate
        if result.isLiveOnly {
            isSearching = true
            coordinate = await MapHomeSearchRunner.appleCoordinate(for: result)
            isSearching = false
        }
        guard let coordinate,
              let place = PlanSpot(place: PlanPlace(name: result.title, latitude: coordinate.latitude, longitude: coordinate.longitude), plannedSpendKRW: nil).place else {
            notice = language.text(
                "이곳의 좌표를 Apple 지도에서 찾지 못했습니다. 다른 결과를 골라 주세요.",
                "Couldn't find this place's coordinates in Apple Maps. Pick another result."
            )
            return
        }
        choose(place)
    }
}
