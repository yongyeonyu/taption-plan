import Foundation
import TaptionWatchSync
import TaptionPlanCore

public enum CatStyle: String, Codable, CaseIterable, Sendable {
    case white
    case calico
    case mackerel
    case black
    case gray
    case cheese
    case cow
}

public struct MapUserActivityCategory: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var systemImage: String
    public var hex: String
    /// 사용자가 고른 화랑이 동작. 옛 설정에는 없다.
    public var animation: MapUserActivityAnimation? = nil

    public init(
        id: UUID,
        title: String,
        systemImage: String,
        hex: String,
        animation: MapUserActivityAnimation? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.hex = hex
        self.animation = animation
    }
}

/// 행동 분류에 쓰지 않는 동작 중 사용자 추가 분류에 고를 수 있는 것(CAT1103A03).
public enum MapUserActivityAnimation: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case mapReading
    case walkInPlace
    case stretching
    case grooming
    case yarnPlay
    case catWheel
    case puzzled

    public var id: Self { self }

    public var title: String {
        switch self {
        case .mapReading: AppLanguagePreference.text(korean: "지도 펼쳐 보기", english: "Reading a map")
        case .walkInPlace: AppLanguagePreference.text(korean: "제자리 걷기", english: "Walking in place")
        case .stretching: AppLanguagePreference.text(korean: "스트레칭", english: "Stretching")
        case .grooming: AppLanguagePreference.text(korean: "그루밍", english: "Grooming")
        case .yarnPlay: AppLanguagePreference.text(korean: "털실 놀이", english: "Playing with yarn")
        case .catWheel: AppLanguagePreference.text(korean: "캣휠", english: "Cat wheel")
        case .puzzled: AppLanguagePreference.text(korean: "갸우뚱", english: "Puzzled")
        }
    }
}

public enum MapDisplayProvider: CaseIterable, Hashable, Sendable {
    case apple
    case openFreeMap
}

public enum MapDisplayStyle: String, Codable, CaseIterable, Sendable {
    case standard
    /// 화면 이름은 "위성"(항공 사진 + 도로·지명). 저장값 호환을 위해 hybrid를 유지한다.
    case hybrid
    case mapLibreNight
    case mapLibreContrast
    case mapLibreCasual
    case mapLibreRPG
    /// 수묵(INK1108A01). 예전 앱은 모르는 값을 `standard`로 읽으므로 백업을 깨지 않는다.
    case mapLibreInk
    /// 백자(PLN1111A01): 가라앉힌 땅·길 위에 경로가 뚜렷한 모양. 예전 앱은 모르는 값을 `standard`로 읽는다.
    case mapLibrePorcelain

    /// 없앤 스타일(밝게·파스텔, UIX1101A03)로 저장된 값은 가장 비슷한 산책 지도로 읽는다.
    public static let retiredRawValues: Set<String> = ["mapLibreLight", "mapLibrePastel"]

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        if Self.retiredRawValues.contains(value) {
            self = .mapLibreCasual
        } else {
            self = Self(rawValue: value) ?? .standard
        }
    }
}

public enum MapMemoDisplayFilter: String, Codable, CaseIterable, Hashable, Sendable {
    case all
    case relevant
}

public enum MapStickerPlacement: String, Codable, CaseIterable, Hashable, Sendable {
    case map
    case schedule
}

public struct MapSticker: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var memo: String?
    public var systemImage: String
    public var colorHex: String
    public var placement: MapStickerPlacement
    public var point: GeoPoint?
    public var planID: UUID?
    public var occurredAt: Date
    public var createdAt: Date
    public var updatedAt: Date

    public init(
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
    public static let appleStyles: [Self] = [
        .standard,
        .hybrid,
    ]

    public static let openFreeMapStyles: [Self] = [
        .mapLibreRPG,
        .mapLibreCasual,
        .mapLibreNight,
        .mapLibreContrast,
        .mapLibreInk,
        .mapLibrePorcelain,
    ]

    public var provider: MapDisplayProvider {
        switch self {
        case .standard, .hybrid:
            .apple
        case .mapLibreNight,
             .mapLibreContrast,
             .mapLibreCasual,
             .mapLibreRPG,
             .mapLibreInk,
             .mapLibrePorcelain:
            .openFreeMap
        }
    }

    public static func defaultStyle(for provider: MapDisplayProvider) -> Self {
        switch provider {
        case .apple: .standard
        case .openFreeMap: .mapLibreRPG
        }
    }

    public var runtimeStyle: Self { self }
}

public enum MapUserActivityIconCatalog {
    public static let candidates = [
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

    public static func available(
        for customCategories: [MapUserActivityCategory]
    ) -> [String] {
        let used = Set(
            RecordClassificationCatalog.categories.map(\.systemImage)
                + customCategories.map(\.systemImage)
        )
        return candidates.filter { !used.contains($0) }
    }
}
