import Foundation
import TaptionPlanCore

enum CatStyle: String, Codable, CaseIterable, Sendable {
    case white
    case calico
    case mackerel
    case black
    case gray
    case cheese
    case cow
}

struct MapUserActivityCategory: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var systemImage: String
    var hex: String
}

enum MapDisplayProvider: CaseIterable, Hashable, Sendable {
    case apple
    case openFreeMap
}

enum MapDisplayStyle: String, Codable, CaseIterable, Sendable {
    case standard
    /// 화면 이름은 "위성"(항공 사진 + 도로·지명). 저장값 호환을 위해 hybrid를 유지한다.
    case hybrid
    case mapLibreNight
    case mapLibreContrast
    case mapLibreCasual
    case mapLibreRPG

    /// 없앤 스타일(밝게·파스텔, UIX1101A03)로 저장된 값은 가장 비슷한 산책 지도로 읽는다.
    static let retiredRawValues: Set<String> = ["mapLibreLight", "mapLibrePastel"]

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        if Self.retiredRawValues.contains(value) {
            self = .mapLibreCasual
        } else {
            self = Self(rawValue: value) ?? .standard
        }
    }
}

enum MapMemoDisplayFilter: String, Codable, CaseIterable, Hashable, Sendable {
    case all
    case relevant
}

enum MapStickerPlacement: String, Codable, CaseIterable, Hashable, Sendable {
    case map
    case schedule
}

struct MapSticker: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var memo: String?
    var systemImage: String
    var colorHex: String
    var placement: MapStickerPlacement
    var point: GeoPoint?
    var planID: UUID?
    var occurredAt: Date
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        memo: String? = nil,
        systemImage: String = "star.fill",
        colorHex: String = "#F28FA9",
        placement: MapStickerPlacement,
        point: GeoPoint? = nil,
        planID: UUID? = nil,
        occurredAt: Date,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.memo = memo
        self.systemImage = systemImage
        self.colorHex = colorHex
        self.placement = placement
        self.point = point
        self.planID = planID
        self.occurredAt = occurredAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension MapDisplayStyle {
    static let appleStyles: [Self] = [
        .standard,
        .hybrid,
    ]

    static let openFreeMapStyles: [Self] = [
        .mapLibreRPG,
        .mapLibreCasual,
        .mapLibreNight,
        .mapLibreContrast,
    ]

    var provider: MapDisplayProvider {
        switch self {
        case .standard, .hybrid:
            .apple
        case .mapLibreNight,
             .mapLibreContrast,
             .mapLibreCasual,
             .mapLibreRPG:
            .openFreeMap
        }
    }

    static func defaultStyle(for provider: MapDisplayProvider) -> Self {
        switch provider {
        case .apple: .standard
        case .openFreeMap: .mapLibreRPG
        }
    }

    var runtimeStyle: Self { self }
}

enum MapUserActivityIconCatalog {
    static let candidates = [
        "tag.fill", "star.fill", "heart.fill", "bolt.fill",
        "flag.fill", "bookmark.fill", "pin.fill", "bell.fill",
        "gift.fill", "trophy.fill", "medal.fill", "crown.fill",
        "lightbulb.fill", "brain.head.profile", "puzzlepiece.fill",
        "gamecontroller.fill", "headphones", "music.note", "mic.fill",
        "camera.fill", "photo.fill", "film.fill", "paintbrush.fill",
        "hammer.fill", "wrench.and.screwdriver.fill", "leaf.fill",
        "flame.fill", "drop.fill", "sun.max.fill", "moon.stars.fill",
        "cup.and.saucer.fill", "takeoutbag.and.cup.and.straw.fill",
        "cart.fill", "bag.fill", "creditcard.fill", "banknote.fill",
        "person.2.fill", "person.3.fill", "bubble.left.and.bubble.right.fill",
        "phone.fill", "envelope.fill", "paperplane.fill",
        "desktopcomputer", "laptopcomputer", "keyboard.fill",
        "printer.fill", "shippingbox.fill", "archivebox.fill",
    ]

    static func available(
        for customCategories: [MapUserActivityCategory]
    ) -> [String] {
        let used = Set(
            RecordClassificationCatalog.categories.map(\.systemImage)
                + customCategories.map(\.systemImage)
        )
        return candidates.filter { !used.contains($0) }
    }
}
