import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

enum MapHomeUserLocationSelection: Identifiable, Hashable {
    case frequentPlace(UUID)
    case transit(UUID)

    var id: String {
        switch self {
        case .frequentPlace(let id): "frequent-" + id.uuidString
        case .transit(let id): "transit-" + id.uuidString
        }
    }
}

struct MapHomeUserLocationActionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let selection: MapHomeUserLocationSelection
    let language: MapHomeLanguage

    @State private var name = ""
    @State private var isEditing = false
    @State private var showsDeleteConfirmation = false

    private var frequentPlace: FrequentPlace? {
        guard case .frequentPlace(let id) = selection else { return nil }
        return model.settings.frequentPlaces.first { $0.id == id }
    }

    private var transitLocation: UserTransitLocation? {
        guard case .transit(let id) = selection else { return nil }
        return model.settings.userTransitLocations.first { $0.id == id }
    }

    private var locationName: String {
        if let frequentPlace { return frequentPlace.displayName }
        return transitLocation?.name ?? ""
    }

    private var locationSubtitle: String {
        if let transitLocation {
            return language.runtimeText(
                transitLocation.kind.title,
                transitLocation.kind.englishTitle
            )
        }
        if frequentPlace?.kind == .restaurant {
            return language.text("등록 식당", "Restaurant")
        }
        return language.text("사용자 위치", "User location")
    }

    private var locationIcon: String {
        transitLocation?.kind.systemImage
            ?? frequentPlace?.kind.systemImage
            ?? FrequentPlaceKind.custom.systemImage
    }

    private var locationTint: Color {
        if let frequentPlace,
           let destination = MapHomeLocationDestination(placeKind: frequentPlace.kind) {
            return destination.tint
        }
        return transitLocation == nil
            ? MapHomeLocationDestination.user.tint
            : Color.tpReferenceBlue
    }

    var body: some View {
        ScrollView {
            content
        }
        .background(Color.tpSurface)
        .onAppear {
            name = locationName
        }
        .confirmationDialog(
            language.text("이 위치를 삭제할까요?", "Delete this location?"),
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.text("위치 삭제", "Delete location"), role: .destructive) {
                deleteLocation()
            }
            Button(language.text("취소", "Cancel"), role: .cancel) {}
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: locationIcon)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(18)), weight: .semibold))
                    .foregroundStyle(locationTint)
                    .frame(width: 34, height: 34)
                    .background(
                        locationTint.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(locationName)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(19)), weight: .bold))
                        .lineLimit(1)
                    Text(locationSubtitle)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if isEditing {
                TextField(
                    language.text("위치 이름", "Location name"),
                    text: $name
                )
                .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    Button(language.text("취소", "Cancel")) {
                        name = locationName
                        isEditing = false
                    }
                    .buttonStyle(.bordered)

                    Button(language.text("저장", "Save")) {
                        saveName()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button {
                    name = locationName
                    isEditing = true
                } label: {
                    Label(
                        language.text("위치 편집", "Edit location"),
                        systemImage: "pencil"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Label(
                        language.text("위치 삭제", "Delete location"),
                        systemImage: "trash"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }

            if let frequentPlace {
                MapHomePlaceRangeEditor(model: model, placeID: frequentPlace.id, language: language)
            }
        }
        .padding(20)
    }

    private func saveName() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        switch selection {
        case .frequentPlace(let id):
            model.renameFrequentPlace(id, name: cleanName)
        case .transit(let id):
            model.renameUserTransitLocation(id, name: cleanName)
        }
        name = cleanName
        isEditing = false
    }

    private func deleteLocation() {
        switch selection {
        case .frequentPlace(let id):
            model.deleteFrequentPlace(id)
        case .transit(let id):
            model.deleteUserTransitLocation(id)
        }
        dismiss()
    }
}

struct MapHomeSearchPinLocationSheet: View {
    @Bindable var model: AppModel
    let result: MapHomeSearchResult
    let language: MapHomeLanguage
    let onSaved: (MapHomeUserLocationSelection?) -> Void
    @State private var floor = 1
    @State private var appleCoordinate: CLLocationCoordinate2D?
    @State private var isResolving = false

    /// 카카오 좌표는 저장하지 않는다. 같은 장소의 Apple 좌표로 바꿔 저장한다.
    private var saveCoordinate: CLLocationCoordinate2D { appleCoordinate ?? result.coordinate }
    private var canSave: Bool { !result.isLiveOnly || appleCoordinate != nil }

    /// 내용 높이에 맞춘 팝업 높이. 대중교통 줄이 붙으면서 고정 540pt를 넘어 제목이 잘렸다.
    @State private var contentHeight: CGFloat = 540

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                    let rounded = height.rounded(.up)
                    if rounded != contentHeight { contentHeight = rounded }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.tpSurface)
        .presentationDetents([.height(contentHeight + 12)])
        .presentationBackgroundInteraction(.enabled(upThrough: .height(contentHeight + 12)))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(language.text("위치 추가", "Add location"))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(20)), weight: .bold))
            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold))
                if !result.subtitle.isEmpty {
                    Text(result.subtitle)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if result.isLiveOnly, !isResolving, appleCoordinate == nil {
                Text(language.text("이 장소는 바로 저장할 수 없어요. 지도를 길게 눌러 직접 추가해 주세요.", "This place can't be saved directly. Long-press the map to add it."))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                    .foregroundStyle(.secondary)
            }

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
            .task {
                guard result.isLiveOnly else { return }
                isResolving = true
                appleCoordinate = await MapHomeSearchRunner.appleCoordinate(for: result)
                isResolving = false
            }

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                ForEach(MapHomeLocationDestination.allCases) { destination in
                    Button {
                        save(destination)
                    } label: {
                        HStack(spacing: 8) {
                            Image(destination.iconAssetName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 24, height: 24)
                            Text(language.runtimeText(destination.koreanName, destination.englishName))
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 11)
                        .background(
                            destination.tint.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Text(language.text("대중교통 위치", "Transit location"))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                ForEach(UserTransitLocationKind.allCases, id: \.self) { kind in
                    Button {
                        saveTransit(kind)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: kind.systemImage)
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                                .foregroundStyle(Color.tpReferenceBlue)
                            Text(
                                language.runtimeText(
                                    kind.title,
                                    kind.englishTitle
                                )
                            )
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 11)
                        .background(
                            Color.tpReferenceBlue.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .padding(.top, 8)
    }

    private func save(_ destination: MapHomeLocationDestination) {
        guard canSave else { return }
        let latitude = saveCoordinate.latitude
        let longitude = saveCoordinate.longitude
        if destination == .restaurant {
            let restaurantName = resolvedRestaurantName
            model.addRestaurant(name: restaurantName)
            if let place = model.settings.frequentPlaces.last(where: {
                $0.kind == .restaurant && $0.name == restaurantName
            }) {
                model.setFrequentPlaceLocation(
                    place.id,
                    latitude: latitude,
                    longitude: longitude,
                    floor: floor
                )
            }
        } else if let kind = destination.placeKind,
                  let place = model.settings.frequentPlaces.first(where: {
                      $0.kind == kind
                  }) {
            model.setFrequentPlaceLocation(
                place.id,
                latitude: latitude,
                longitude: longitude,
                floor: floor
            )
        } else if destination == .user {
            model.addCustomFrequentPlace(name: result.title)
            if let place = model.settings.frequentPlaces.last(where: {
                $0.kind == .custom && $0.name == result.title
            }) {
                model.setFrequentPlaceLocation(
                    place.id,
                    latitude: latitude,
                    longitude: longitude,
                    floor: floor
                )
            }
        }
        onSaved(nil)
    }

    private var resolvedRestaurantName: String {
        let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              title != "사용자 지점",
              title.caseInsensitiveCompare("User location") != .orderedSame
        else {
            let names = Set(
                model.settings.frequentPlaces
                    .filter { $0.kind == .restaurant }
                    .map(\.name)
            )
            if !names.contains("식당") { return "식당" }
            var suffix = 2
            while names.contains("식당 \(suffix)") { suffix += 1 }
            return "식당 \(suffix)"
        }
        return title
    }

    private func saveTransit(_ kind: UserTransitLocationKind) {
        guard canSave else { return }
        let cleanName = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let createdID = model.addUserTransitLocation(
            name: cleanName.isEmpty ? kind.title : cleanName,
            kind: kind,
            latitude: saveCoordinate.latitude,
            longitude: saveCoordinate.longitude,
            floor: floor
        ) else { return }
        onSaved(.transit(createdID))
    }
}
