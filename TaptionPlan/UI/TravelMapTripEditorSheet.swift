import CoreLocation
import MapKit
import SwiftUI

/// 기록 없이 여행을 직접 넣는 목록 편집기(TRV1108A01). 도시·구간 수단·날짜만 고른다.
/// 도시는 앱 안 도시 목록에서 먼저 찾고(오프라인), 없으면 지도 검색(현재 위치 둘레)으로 찾는다.
struct TravelMapTripEditorSheet: View {
    let language: MapHomeLanguage
    @Binding var trip: TravelMapTrip

    private struct Candidate: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let coordinate: CLLocationCoordinate2D
    }

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var candidates: [Candidate] = []
    @State private var notice: String?

    /// 도시 검색이라 화면 범위가 아니라 나라 하나쯤을 본다.
    private static let searchSpanDegrees = 6.0
    private static let resultLimit = 8

    var body: some View {
        NavigationStack {
            List {
                Section(language.text("도시", "Cities")) {
                    ForEach($trip.stops) { $stop in
                        row($stop)
                    }
                    .onDelete { trip.stops.remove(atOffsets: $0) }
                    .onMove { trip.stops.move(fromOffsets: $0, toOffset: $1) }
                }
                Section(language.text("도시 추가", "Add city")) {
                    TextField(language.text("도시 이름 검색", "Search city name"), text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                    ForEach(candidates) { candidate in
                        Button { add(candidate) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.title).foregroundStyle(Color.tpInk)
                                if !candidate.subtitle.isEmpty {
                                    Text(candidate.subtitle)
                                        .font(.taptionStyle(.caption))
                                        .foregroundStyle(Color.tpSecondary)
                                }
                            }
                        }
                    }
                    if let notice {
                        Text(notice).font(.taptionStyle(.caption)).foregroundStyle(Color.tpSecondary)
                    }
                }
            }
            .navigationTitle(language.text("여행 경로", "Trip route"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(language.text("완료", "Done")) { dismiss() }
                }
            }
            .task(id: query) { await search() }
        }
    }

    private func row(_ stop: Binding<TravelMapStop>) -> some View {
        let isFirst = trip.stops.first?.id == stop.wrappedValue.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if !isFirst {
                    Menu {
                        Picker(language.text("이동 수단", "Transport"), selection: stop.arrivalMode) {
                            ForEach(TravelMapMode.allCases, id: \.self) { mode in
                                Label(mode.title(language), systemImage: mode.symbolName).tag(mode)
                            }
                        }
                    } label: {
                        Image(systemName: stop.wrappedValue.arrivalMode.symbolName)
                            .frame(width: 32, height: 32)
                            .foregroundStyle(Color.tpAccent)
                            .background(Color.tpSurface, in: Circle())
                    }
                    .accessibilityLabel(stop.wrappedValue.arrivalMode.title(language))
                }
                Text(stop.wrappedValue.name)
                    .font(.taptionStyle(.headline))
                    .foregroundStyle(Color.tpInk)
                Spacer(minLength: 4)
                DatePicker("", selection: stop.date, displayedComponents: .date)
                    .labelsHidden()
            }
        }
    }

    private func add(_ candidate: Candidate) {
        trip.append(name: candidate.title, coordinate: candidate.coordinate)
        query = ""
        candidates = []
        notice = nil
    }

    /// 앱 안 목록은 바로, 지도 검색은 입력이 멈춘 뒤에 찾는다.
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        notice = nil
        guard !text.isEmpty else {
            candidates = []
            return
        }
        let local = TravelMapCityCatalog.bundled.search(text).map { city in
            Candidate(
                title: city.name(language),
                subtitle: language.text("앱 안 도시 목록", "Built-in city list"),
                coordinate: city.coordinate
            )
        }
        candidates = local
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.address, .pointOfInterest]
        request.region = MapHomeSearchPolicy.region(
            visibleCenter: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            visibleSpan: MKCoordinateSpan(latitudeDelta: Self.searchSpanDegrees, longitudeDelta: Self.searchSpanDegrees),
            current: CLLocationManager().location?.coordinate
        )
        var failed = false
        var items: [MKMapItem] = []
        do { items = try await MKLocalSearch(request: request).start().mapItems } catch {
            // 결과가 없으면 Apple 검색은 placemarkNotFound 오류를 낸다. 그때는 실패가 아니다.
            failed = (error as? MKError)?.code != .placemarkNotFound
        }
        guard !Task.isCancelled else { return }
        // 도시 지도라 장소 이름보다 그 장소가 속한 시·군 이름을 쓴다. 같은 이름은 한 번만 보인다.
        var names = Set(local.map(\.title))
        let found = items.compactMap { item -> Candidate? in
            let title = item.placemark.locality ?? item.name ?? text
            guard names.insert(title).inserted else { return nil }
            return Candidate(title: title, subtitle: item.placemark.title ?? "", coordinate: item.placemark.coordinate)
        }
        candidates = Array((local + found).prefix(Self.resultLimit))
        if candidates.isEmpty {
            notice = failed
                ? language.text("검색하지 못했습니다. 연결을 확인해 주세요.", "Search failed. Check your connection.")
                : language.text("검색 결과가 없습니다.", "No results.")
        }
    }
}
