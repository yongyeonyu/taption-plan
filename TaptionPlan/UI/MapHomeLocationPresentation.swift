import SwiftUI

enum MapHomeLocationDestination: String, CaseIterable, Identifiable {
    case home
    case company
    case school
    case exercise
    case hobby
    case user

    var id: String { rawValue }

    var placeKind: FrequentPlaceKind? {
        switch self {
        case .home: .home
        case .company: .company
        case .school: .school
        case .exercise: .exercise
        case .hobby: .hobby
        case .user: nil
        }
    }

    init?(placeKind: FrequentPlaceKind) {
        switch placeKind {
        case .home: self = .home
        case .company: self = .company
        case .school: self = .school
        case .exercise: self = .exercise
        case .hobby: self = .hobby
        case .academy, .custom: return nil
        }
    }

    var koreanName: String {
        switch self {
        case .home: "집"
        case .company: "회사"
        case .school: "학교"
        case .exercise: "운동"
        case .hobby: "취미"
        case .user: "사용자"
        }
    }

    var englishName: String {
        switch self {
        case .home: "Home"
        case .company: "Work"
        case .school: "School"
        case .exercise: "Exercise"
        case .hobby: "Hobby"
        case .user: "User"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .company: "building.2.fill"
        case .school: "graduationcap.fill"
        case .exercise: "figure.run"
        case .hobby: "paintpalette.fill"
        case .user: "mappin.and.ellipse"
        }
    }

    var tint: Color {
        switch self {
        case .home: Color.tpReferenceGold
        case .company: Color.tpReferenceBlue
        case .school: Color.tpReferenceMint
        case .exercise: Color.tpReferenceRose
        case .hobby: Color(red: 0.58, green: 0.40, blue: 0.78)
        case .user: Color.tpReferenceRose
        }
    }
}

struct MapHomeLocationThumbnail: View {
    let destination: MapHomeLocationDestination
    var size: CGFloat = 42

    var body: some View {
        Group {
            if destination == .home {
                Image("MapHomeHouseMarker")
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .fill(destination.tint.opacity(0.14))
                    Image(systemName: destination.systemImage)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(destination.tint)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
