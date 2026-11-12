import MapKit
import SwiftUI

/// 일정에 붙일 장소 찾기(TVX1112A01): 이름으로 찾아 하나를 고른다. 여행지 둘레를 먼저 본다.
struct TravelPlacePicker: View {
    let language: MapHomeLanguage
    /// 처음에 넣어 둘 찾을 말(일정 이름).
    let query: String
    /// 여행지 가운데(경도, 위도). 있으면 그 둘레를 먼저 찾는다.
    let anchor: SIMD2<Double>?
    let onPick: (TravelItemPlace) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var text = ""
    @State private var results: [TravelItemPlace] = []
    @State private var details: [String: String] = [:]
    @State private var isSearching = false
    @State private var didSearch = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField(language.text("장소 이름", "Place name"), text: $text)
                            .focused($isFocused)
                            .submitLabel(.search)
                            .onSubmit { Task { await search() } }
                            .accessibilityIdentifier("travelPlaceQuery")
                        if isSearching { ProgressView() }
                    }
                }
                Section {
                    ForEach(results) { place in
                        Button {
                            onPick(place)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name).foregroundStyle(TravelInk.plan)
                                if let detail = details[place.id], !detail.isEmpty {
                                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                    if didSearch, results.isEmpty, !isSearching {
                        Text(language.text("찾은 곳이 없습니다. 다른 이름으로 찾아 보세요.", "Nothing found. Try another name.")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(language.text("장소 찾기", "Find a place"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(language.text("취소", "Cancel")) { dismiss() } } }
            .onAppear {
                text = query
                isFocused = true
                if !query.isEmpty { Task { await search() } }
            }
        }
        .preferredColorScheme(.light)
    }

    private func search() async {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return }
        isSearching = true
        defer {
            isSearching = false
            didSearch = true
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = wanted
        if let anchor {
            request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: anchor.y, longitude: anchor.x), latitudinalMeters: 200_000, longitudinalMeters: 200_000)
        }
        let items = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
        var found: [TravelItemPlace] = [], notes: [String: String] = [:]
        for item in items.prefix(15) {
            let coordinate = item.placemark.coordinate
            let place = TravelItemPlace(name: item.name ?? wanted, latitude: coordinate.latitude, longitude: coordinate.longitude)
            guard !found.contains(place) else { continue }
            found.append(place)
            notes[place.id] = item.placemark.title ?? ""
        }
        results = found
        details = notes
    }
}
