import Foundation
import SwiftUI

enum MapHomeLocationDestination: String, CaseIterable, Identifiable {
    case home
    case company
    case school
    case academy
    case exercise
    case hobby
    case restaurant
    case user

    var id: String { rawValue }

    /// 앱 그림체로 그린 위치 아이콘(`tools/generate_place_icons.py`).
    var iconAssetName: String { "PlaceIcon_\(rawValue)" }

    var placeKind: FrequentPlaceKind? {
        switch self {
        case .home: .home
        case .company: .company
        case .school: .school
        case .academy: .academy
        case .exercise: .exercise
        case .hobby: .hobby
        case .restaurant: .restaurant
        case .user: nil
        }
    }

    init?(placeKind: FrequentPlaceKind) {
        switch placeKind {
        case .home: self = .home
        case .company: self = .company
        case .school: self = .school
        case .academy: self = .academy
        case .exercise: self = .exercise
        case .hobby: self = .hobby
        case .restaurant: self = .restaurant
        case .custom: self = .user
        }
    }

    var koreanName: String {
        switch self {
        case .home: "집"
        case .company: "회사"
        case .school: "학교"
        case .academy: "학원"
        case .exercise: "운동"
        case .hobby: "취미"
        case .restaurant: "식당"
        case .user: "사용자"
        }
    }

    var englishName: String {
        switch self {
        case .home: "Home"
        case .company: "Work"
        case .school: "School"
        case .academy: "Academy"
        case .exercise: "Exercise"
        case .hobby: "Hobby"
        case .restaurant: "Restaurant"
        case .user: "User"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .company: "building.2.fill"
        case .school: "graduationcap.fill"
        case .academy: "book.closed.fill"
        case .exercise: "figure.run"
        case .hobby: "paintpalette.fill"
        case .restaurant: "storefront.fill"
        case .user: "mappin.and.ellipse"
        }
    }

    /// RPG 탐험 테마의 랜드마크 아이콘. 집=오두막, 회사=길드 성,
    /// 학교=지식의 탑, 학원=마법 연구소, 운동=훈련장, 취미=공연장,
    /// 식당=주점. 지도 배지에서 판타지 느낌을 준다.
    var rpgSystemImage: String {
        switch self {
        case .home: "tent.fill"
        case .company: "building.columns.fill"
        case .school: "books.vertical.fill"
        case .academy: "wand.and.stars"
        case .exercise: "figure.strengthtraining.traditional"
        case .hobby: "theatermasks.fill"
        case .restaurant: "fork.knife"
        case .user: "flag.fill"
        }
    }

    var tint: Color {
        // Low-chroma terrain colors keep every registered landmark in the
        // same parchment-map palette while preserving category distinction.
        switch self {
        case .home: Color(hex: "#976744")
        case .company: Color(hex: "#65745E")
        case .school: Color(hex: "#7B6C55")
        case .academy: Color(hex: "#796D82")
        case .exercise: Color(hex: "#A75F4A")
        case .hobby: Color(hex: "#987F4D")
        case .restaurant: Color(hex: "#A56347")
        case .user: Color(hex: "#756E5B")
        }
    }
}

struct MapHomeLocationThumbnail: View {
    let destination: MapHomeLocationDestination
    var size: CGFloat = 42

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(destination.tint.opacity(0.14))
            Image(destination.iconAssetName)
                .resizable()
                .scaledToFit()
                .padding(size * 0.1)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 행동 분류 메뉴의 상세 항목과 그 화랑이 장면(CAT1103A02).
struct MapHomeCategoryDetailRows: View {
    let categoryID: String
    let language: MapHomeLanguage
    let accessoryID: String?

    /// 기본 상세 목록과, 센서로 정할 수 없어 「직접 추가」로 따로 둔 상세(DTL1111A01).
    static func details(for categoryID: String) -> [RecordClassificationDetail] { allDetails(categoryID).filter { $0.userAdded != true } }
    static func userAddedDetails(for categoryID: String) -> [RecordClassificationDetail] { allDetails(categoryID).filter { $0.userAdded == true } }
    private static func allDetails(_ categoryID: String) -> [RecordClassificationDetail] {
        categoryID == "unconfirmed" ? [] : RecordClassificationCatalog.categories.first { $0.id == categoryID }?.details ?? []
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Self.details(for: categoryID)) { detail in
                HStack(spacing: 8) {
                    MapHomeStickmanGlyph(
                        action: MapHomeStickmanActionResolver.action(for: detail.id, label: detail.title),
                        size: 28,
                        equippedAccessoryID: accessoryID
                    )
                    .frame(width: 46, height: 38)
                    .clipped()
                    Text(detail.localizedTitle(language))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                        .foregroundStyle(Color.tpInk)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 19)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
