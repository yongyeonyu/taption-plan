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
        if let frequentPlace {
            let name = frequentPlace.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if frequentPlace.kind == .restaurant,
               name.isEmpty || name == "사용자 지점"
                    || name.caseInsensitiveCompare("User location") == .orderedSame {
                return "식당"
            }
            return name
        }
        return transitLocation?.name ?? ""
    }

    private var locationSubtitle: String {
        if let transitLocation {
            return language.text(
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
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(19)), weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(locationSubtitle)
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium, design: .rounded))
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

            Spacer(minLength: 0)
        }
        .padding(20)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(language.text("위치 추가", "Add location"))
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(20)), weight: .bold, design: .rounded))
            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold, design: .rounded))
                if !result.subtitle.isEmpty {
                    Text(result.subtitle)
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            Stepper(value: $floor, in: FloorCalibrationPrompt.range) {
                HStack {
                    Text(language.text("저장할 층수", "Floor to save"))
                    Spacer()
                    Text(FloorLabel.korean(floor))
                        .fontWeight(.bold)
                        .foregroundStyle(Color.tpReferenceBlue)
                }
            }
            .tint(Color.tpReferenceBlue)

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
                            Text(language.text(destination.koreanName, destination.englishName))
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold, design: .rounded))
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
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold, design: .rounded))
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
                                language.text(
                                    kind.title,
                                    kind.englishTitle
                                )
                            )
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold, design: .rounded))
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
            Spacer()
        }
        .padding(20)
        .background(Color.tpSurface)
    }

    private func save(_ destination: MapHomeLocationDestination) {
        let latitude = result.coordinate.latitude
        let longitude = result.coordinate.longitude
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
        let cleanName = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let createdID = model.addUserTransitLocation(
            name: cleanName.isEmpty ? kind.title : cleanName,
            kind: kind,
            latitude: result.coordinate.latitude,
            longitude: result.coordinate.longitude,
            floor: floor
        ) else { return }
        onSaved(.transit(createdID))
    }
}
