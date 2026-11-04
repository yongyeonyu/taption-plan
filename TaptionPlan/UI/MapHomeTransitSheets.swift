import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

struct MapHomePredictedRouteMenu: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var saveFailed = false
    let model: AppModel
    let route: MapPredictedRoute
    let language: MapHomeLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(language.text("선택한 회색 경로", "Selected predicted route"))
                .font(.taptionFixed(size: 17, weight: .semibold))
            Button { save(deleting: false) } label: {
                Label(language.text("변경", "Confirm"), systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving)
            Button(role: .destructive) { save(deleting: true) } label: {
                Label(language.text("삭제", "Delete"), systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .disabled(isSaving)
            if saveFailed {
                Text(language.text("저장하지 못했습니다. 다시 시도해 주세요.", "Couldn’t save. Please try again."))
                    .font(.taptionFixed(size: 13)).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .interactiveDismissDisabled(isSaving)
    }

    private func save(deleting: Bool) {
        isSaving = true
        saveFailed = false
        Task { @MainActor in
            if await model.savePredictedRouteDecision(route, deleting: deleting) { dismiss() }
            else { saveFailed = true }
            isSaving = false
        }
    }
}

struct MapHomeTransitBoardingCandidateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    @State private var isSaving = false
    @State private var saveFailed = false
    let candidate: TransitBoardingCandidate
    let language: MapHomeLanguage

    private var dwellText: String {
        let minutes = max(3, Int((candidate.dwellDuration / 60).rounded(.down)))
        return language.text("\(minutes)분 체류 후보", "Stayed \(minutes) minutes")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: candidate.kind.systemImage)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(18)), weight: .semibold))
                    .foregroundStyle(Color.tpTransitDark)
                    .frame(width: 38, height: 38)
                    .background(
                        Color.tpTransitDark.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(TransitPlaceName.display(candidate.name, kind: candidate.kind, point: candidate.point, language: language))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(19)), weight: .bold))
                        .lineLimit(1)
                    Text(
                        language.text(
                            "\(candidate.kind.title) · \(dwellText)",
                            "\(candidate.kind.englishTitle) · \(dwellText)"
                        )
                    )
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Button {
                isSaving = true
                saveFailed = false
                Task { @MainActor in
                    if await model.confirmTransitBoarding(candidate) {
                        dismiss()
                    } else {
                        saveFailed = true
                    }
                    isSaving = false
                }
            } label: {
                Label(
                    language.runtimeText(
                        AppLanguagePreference.text(korean: "\(MovementPresentation.title(for: candidate.mode)) 탑승", english: "\(MovementPresentation.englishTitle(for: candidate.mode)) ride"),
                        "Board \(MovementPresentation.englishTitle(for: candidate.mode))"
                    ),
                    systemImage: candidate.mode == .subway
                        ? "tram.fill"
                        : candidate.mode == .bus
                            ? "bus.fill"
                            : MovementPresentation.symbol(for: candidate.mode)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.tpReferenceBlue)
            .disabled(isSaving)

            Button(role: .destructive) {
                isSaving = true
                saveFailed = false
                Task { @MainActor in
                    if await model.deleteTransitBoardingCandidate(candidate) {
                        dismiss()
                    } else {
                        saveFailed = true
                    }
                    isSaving = false
                }
            } label: {
                Label(
                    language.text("이 후보 삭제", "Delete this candidate"),
                    systemImage: "trash"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .disabled(isSaving)

            if saveFailed {
                Text(language.text("저장하지 못했습니다. 다시 시도해 주세요.",
                    "Couldn’t save. Please try again."))
                    .font(.taptionFixed(size: 13))
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Color.tpSurface)
        .interactiveDismissDisabled(isSaving)
    }
}

struct MapHomeTransitLocationsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let initialCenter: CLLocationCoordinate2D
    let initialSpan: MKCoordinateSpan

    @State private var name = ""
    @State private var kind: UserTransitLocationKind = .subwayStation
    @State private var floor = 1
    @State private var searchText = ""
    @State private var searchResults: [MapHomeSearchResult] = []
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var selectedPinTitle = ""
    @State private var selectedLocationID: UUID?
    @State private var mapPosition: MapCameraPosition
    @State private var editingLocation: UserTransitLocation?
    @State private var deletingLocation: UserTransitLocation?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isTransitSearchFocused: Bool

    init(
        model: AppModel,
        language: MapHomeLanguage,
        initialCenter: CLLocationCoordinate2D,
        initialSpan: MKCoordinateSpan
    ) {
        self.model = model
        self.language = language
        self.initialCenter = initialCenter
        self.initialSpan = initialSpan
        let position: MapCameraPosition
        if CLLocationCoordinate2DIsValid(initialCenter) {
            position = .region(
                MapHomeLocationMapMath.region(center: initialCenter, span: initialSpan)
            )
        } else {
            position = .automatic
        }
        _mapPosition = State(initialValue: position)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                header
                searchCard
                savedLocationsCard
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.tpBackground.ignoresSafeArea())
        .sheet(item: $editingLocation) { location in
            MapHomeTransitLocationNameEditor(
                model: model,
                location: location,
                language: language,
                onSaved: { savedName in
                    if selectedLocationID == location.id {
                        selectedPinTitle = savedName
                    }
                }
            )
        }
        .confirmationDialog(
            language.text("이 위치를 삭제할까요?", "Delete this location?"),
            isPresented: Binding(
                get: { deletingLocation != nil },
                set: { if !$0 { deletingLocation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(language.text("위치 삭제", "Delete location"), role: .destructive) {
                guard let deletingLocation else { return }
                model.deleteUserTransitLocation(deletingLocation.id)
                if selectedLocationID == deletingLocation.id {
                    selectedLocationID = nil
                    selectedCoordinate = nil
                    selectedPinTitle = ""
                    mapPosition = .region(
                        MapHomeLocationMapMath.region(
                            center: initialCenter,
                            span: initialSpan
                        )
                    )
                }
                self.deletingLocation = nil
            }
            Button(language.text("취소", "Cancel"), role: .cancel) {
                deletingLocation = nil
            }
        }
        .onDisappear {
            searchTask?.cancel()
            searchTask = nil
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(language.text("사용자 위치", "User locations"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(24)), weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text(
                    language.text(
                        "지하철역·버스정류장·기차역·공항·항구를 지도에서 관리합니다.",
                        "Manage subway stations, bus stops, train stations, airports, and harbors on the map."
                    )
                )
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
                    .foregroundStyle(Color.tpInk)
                    .frame(width: 42, height: 42)
                    .background(Color.tpInk.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("닫기", "Close"))
        }
    }

    private var searchCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.tpReferenceBlue)
                    TextField(
                        language.text("역·정류장·공항·항구 검색", "Search transit location"),
                        text: $searchText
                    )
                    .focused($isTransitSearchFocused)
                    .submitLabel(.search)
                    .onSubmit { search() }
                    if isTransitSearchFocused || !searchText.isEmpty {
                        Button {
                            isTransitSearchFocused = false
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            language.text("키보드 닫기", "Dismiss keyboard")
                        )
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Color.tpCard, in: RoundedRectangle(cornerRadius: 13))

                Button(language.text("검색", "Search")) { search() }
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 44)
                    .background(Color.tpPrimaryFill, in: RoundedRectangle(cornerRadius: 13))
                    .buttonStyle(.plain)
                    .disabled(
                        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .opacity(
                        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? 0.38
                            : 1
                    )
            }

            if !searchResults.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(searchResults) { result in
                            Button(result.title) {
                                focusMap(
                                    on: result.coordinate,
                                    title: result.title,
                                    locationID: nil
                                )
                                if name.isEmpty { name = result.title }
                                searchResults = []
                            }
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                            .foregroundStyle(Color.tpReferenceBlue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Color.tpReferenceBlue.opacity(0.10),
                                in: Capsule()
                            )
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            MapReader { proxy in
                Map(position: $mapPosition) {
                    if let selectedCoordinate {
                        Marker(
                            selectedPinTitle.isEmpty
                                ? language.text("선택 위치", "Selected location")
                                : selectedPinTitle,
                            coordinate: selectedCoordinate
                        )
                    }
                }
                .mapStyle(.standard(
                    elevation: .flat,
                    emphasis: .muted,
                    pointsOfInterest: .excludingAll,
                    showsTraffic: false
                ))
                .environment(\.colorScheme, .light)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.tpLine.opacity(0.7), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topLeading) {
                    if let liveUserCoordinate,
                       let point = proxy.convert(liveUserCoordinate, to: .local) {
                        MapHomeHistoricalLocationMarker()
                            .position(point)
                            .accessibilityLabel(
                                language.text("현재 위치", "Current location")
                            )
                            .allowsHitTesting(false)
                    }
                }
                .onTapGesture { point in
                    guard let coordinate = proxy.convert(point, from: .local) else { return }
                    focusMap(
                        on: coordinate,
                        title: language.text("선택 위치", "Selected location"),
                        locationID: nil
                    )
                }
            }
            .frame(height: 250)

            Picker(language.text("유형", "Type"), selection: $kind) {
                ForEach(UserTransitLocationKind.allCases, id: \.self) { value in
                    Text(
                        language.runtimeText(
                            value.title,
                            value.englishTitle
                        )
                    )
                    .tag(value)
                }
            }
            .pickerStyle(.segmented)

            Stepper(value: $floor, in: FloorCalibrationPrompt.range) {
                HStack {
                    Text(language.text("저장할 층수", "Floor to save"))
                    Spacer()
                    Text(language.runtimeText(FloorLabel.korean(floor), FloorLabel.english(floor)))
                        .fontWeight(.bold)
                        .foregroundStyle(Color.tpReferenceBlue)
                }
            }
            .tint(Color.tpReferenceBlue)

            HStack(spacing: 8) {
                TextField(language.text("이름", "Name"), text: $name)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(Color.tpCard, in: RoundedRectangle(cornerRadius: 13))
                Button(language.text("추가", "Add")) { addLocation() }
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 44)
                    .background(
                        Color.tpReferenceBlue,
                        in: RoundedRectangle(cornerRadius: 13)
                    )
                    .buttonStyle(.plain)
                    .disabled(!canAddLocation)
                    .opacity(canAddLocation ? 1 : 0.38)
            }
        }
        .padding(14)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 22))
    }

    private var savedLocationsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(language.text("등록된 위치", "Saved locations"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(18)), weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Spacer()
                Text(String(model.settings.userTransitLocations.count))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
                    .foregroundStyle(Color.tpReferenceBlue)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.tpReferenceBlue.opacity(0.10), in: Capsule())
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)

            if model.settings.userTransitLocations.isEmpty {
                Text(
                    language.text(
                        "등록된 교통 위치가 없습니다.",
                        "No transit locations are saved."
                    )
                )
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 18)
            }

            ForEach(model.settings.userTransitLocations) { location in
                HStack(spacing: 4) {
                    Button {
                        focusMap(
                            on: CLLocationCoordinate2D(
                                latitude: location.point.latitude,
                                longitude: location.point.longitude
                            ),
                            title: location.name,
                            locationID: location.id
                        )
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: location.kind.systemImage)
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .bold))
                                .foregroundStyle(Color.tpReferenceBlue)
                                .frame(width: 38, height: 38)
                                .background(
                                    Color.tpReferenceBlue.opacity(0.11),
                                    in: RoundedRectangle(cornerRadius: 11)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(location.name)
                                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold))
                                    .foregroundStyle(Color.tpInk)
                                    .lineLimit(1)
                                Text(
                                    language.runtimeText(
                                        location.kind.title,
                                        location.kind.englishTitle
                                    )
                                )
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                                .foregroundStyle(.secondary)
                                if let floor = location.floor {
                                    Text(language.runtimeText(FloorLabel.korean(floor), FloorLabel.english(floor)))
                                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                                        .foregroundStyle(Color.tpReferenceBlue)
                                }
                            }
                            Spacer()
                            Image(systemName: "location.fill")
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                                .foregroundStyle(
                                    selectedLocationID == location.id
                                        ? Color.tpReferenceRose
                                        : Color.tpSecondary
                                )
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        editingLocation = location
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
                            .foregroundStyle(Color.tpReferenceBlue)
                            .frame(width: 36, height: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        language.text("\(location.name) 이름 편집", "Edit \(location.name)")
                    )

                    Button(role: .destructive) {
                        deletingLocation = location
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                            .foregroundStyle(Color.red)
                            .frame(width: 36, height: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        language.text("\(location.name) 삭제", "Delete \(location.name)")
                    )
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    selectedLocationID == location.id
                        ? Color.tpReferenceBlue.opacity(0.08)
                        : Color.white.opacity(0.78),
                    in: RoundedRectangle(cornerRadius: 15)
                )
            }
        }
        .padding(14)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 22))
    }

    private var canAddLocation: Bool {
        selectedCoordinate != nil
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var liveUserCoordinate: CLLocationCoordinate2D? {
        let reading = MapCurrentLocationAnchorPolicy.latestValidReading(
            in: [model.latestSensorReading, model.liveRouteState.readings.last]
                .compactMap { $0 }
        )
        guard let point = reading?.point,
              point.latitude.isFinite,
              point.longitude.isFinite,
              (-90...90).contains(point.latitude),
              (-180...180).contains(point.longitude) else { return nil }
        return CLLocationCoordinate2D(
            latitude: point.latitude,
            longitude: point.longitude
        )
    }

    private func focusMap(
        on coordinate: CLLocationCoordinate2D,
        title: String,
        locationID: UUID?
    ) {
        selectedCoordinate = coordinate
        selectedPinTitle = title
        selectedLocationID = locationID
        mapPosition = .region(
            MapHomeLocationMapMath.region(center: coordinate, span: initialSpan)
        )
    }

    private func addLocation() {
        guard let selectedCoordinate else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let createdID = model.addUserTransitLocation(
            name: cleanName,
            kind: kind,
            latitude: selectedCoordinate.latitude,
            longitude: selectedCoordinate.longitude,
            floor: floor
        ) else { return }
        selectedPinTitle = cleanName
        selectedLocationID = createdID
        name = ""
        searchText = ""
        searchResults = []
        isTransitSearchFocused = false
    }

    private func search() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            if CLLocationCoordinate2DIsValid(initialCenter) {
                request.region = MKCoordinateRegion(
                    center: initialCenter,
                    span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
                )
            }
            guard let response = try? await MKLocalSearch(request: request).start(),
                  !Task.isCancelled else { return }
            searchResults = response.mapItems.prefix(8).map { item in
                MapHomeSearchResult(
                    title: item.name ?? query,
                    subtitle: item.placemark.title ?? "",
                    coordinate: item.placemark.coordinate
                )
            }
        }
    }
}

struct MapHomeTransitLocationNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let location: UserTransitLocation
    let language: MapHomeLanguage
    let onSaved: (String) -> Void
    @State private var name: String
    @State private var floor: Int

    init(
        model: AppModel,
        location: UserTransitLocation,
        language: MapHomeLanguage,
        onSaved: @escaping (String) -> Void
    ) {
        self.model = model
        self.location = location
        self.language = language
        self.onSaved = onSaved
        _name = State(initialValue: location.name)
        _floor = State(initialValue: location.floor ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(language.text("위치 이름 수정", "Edit location name"))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(20)), weight: .bold))
                .foregroundStyle(Color.tpInk)
            TextField(language.text("이름", "Name"), text: $name)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Color.tpCard, in: RoundedRectangle(cornerRadius: 13))
            Stepper(value: $floor, in: FloorCalibrationPrompt.range) {
                HStack {
                    Text(language.text("층수", "Floor"))
                    Spacer()
                    Text(language.runtimeText(FloorLabel.korean(floor), FloorLabel.english(floor)))
                        .fontWeight(.bold)
                        .foregroundStyle(Color.tpReferenceBlue)
                }
            }
            .tint(Color.tpReferenceBlue)
            HStack(spacing: 8) {
                Button(language.text("취소", "Cancel")) { dismiss() }
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.tpInk.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                    .buttonStyle(.plain)
                Button(language.text("저장", "Save")) {
                    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.renameUserTransitLocation(location.id, name: cleanName)
                    model.setUserTransitLocationFloor(location.id, floor: floor)
                    onSaved(cleanName)
                    dismiss()
                }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.tpPrimaryFill, in: RoundedRectangle(cornerRadius: 13))
                .buttonStyle(.plain)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .background(Color.tpBackground)
        .presentationDetents([.height(270)])
    }
}

/// 역·정류장 이름을 앱 언어로 맞춘다(STN1103A01). Apple 장소 이름은 기기 언어로 오므로 카탈로그와 섞인다.
enum TransitPlaceName {
    static func display(_ name: String, kind: UserTransitLocationKind, point: GeoPoint, language: MapHomeLanguage) -> String {
        let hasHangul = name.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
        let station = kind == .subwayStation ? SubwayStationCatalog.nearest(to: point)?.stationName : nil
        if language == .english {
            if !hasHangul { return name }
            let source = name.hasSuffix("역") ? String(name.dropLast()) : name
            let romanizedName = romanized(source)
            return kind == .subwayStation ? language.text("\(romanizedName)역", "\(romanizedName) Station") : romanizedName
        }
        return hasHangul ? name : station ?? name
    }

    /// 국어의 로마자 표기법을 음절 단위로 적용한다. 받침과 다음 초성의 음운 변화는 연음만 반영한다.
    static func romanized(_ text: String) -> String {
        let initials = ["g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s", "ss", "", "j", "jj", "ch", "k", "t", "p", "h"]
        let vowels = ["a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe", "yo", "u", "wo", "we", "wi", "yu", "eu", "ui", "i"]
        let finals = ["", "k", "k", "k", "n", "n", "n", "t", "l", "k", "m", "l", "l", "l", "p", "l", "m", "p", "p", "t", "t", "ng", "t", "t", "k", "t", "p", "t"]
        let linked = ["", "g", "kk", "g", "n", "n", "n", "d", "r", "g", "m", "r", "r", "r", "p", "r", "m", "b", "b", "s", "ss", "", "j", "ch", "k", "t", "p", "h"]
        var result = ""
        let scalars = Array(text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            guard (0xAC00...0xD7A3).contains(scalar.value) else {
                result.unicodeScalars.append(scalar)
                continue
            }
            let code = Int(scalar.value) - 0xAC00
            let final = code % 28
            result += initials[code / 588] + vowels[(code % 588) / 28]
            // 받침 뒤에 ㅇ으로 시작하는 음절이 오면 받침이 다음 음절로 넘어간다.
            let next = index + 1 < scalars.count ? scalars[index + 1].value : 0
            let linksNext = (0xAC00...0xD7A3).contains(next) && (Int(next) - 0xAC00) / 588 == 11
            result += linksNext ? linked[final] : finals[final]
        }
        return result.prefix(1).uppercased() + result.dropFirst()
    }
}
