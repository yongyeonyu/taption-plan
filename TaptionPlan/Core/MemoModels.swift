import Foundation
import TaptionPlanCore

enum MemoKind: String, Codable, CaseIterable, Sendable {
    case decision
    case idea
    case blocker
    case nextAction
}

enum AttachmentKind: String, Codable, CaseIterable, Sendable {
    case photo
    case audio
}

struct MemoAttachment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var kind: AttachmentKind
    var localIdentifier: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: AttachmentKind,
        localIdentifier: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.localIdentifier = localIdentifier
        self.createdAt = createdAt
    }
}

/// A memo stands on its own. It may point at a plan or at an automatic
/// record, but it never requires one: a note left on a category row keeps that
/// category and the instant it belongs to, so no placeholder plan is needed.
struct ActionMemo: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// Optional link to a user plan. `nil` for standalone memos.
    var planID: UUID?
    /// Stable timeline item key. Plan-backed memos keep using `planID`, while
    /// automatic records (location, travel, health, weather, photos, etc.)
    /// use this key so two records in the same category never share notes.
    var targetID: String?
    /// Category the memo belongs to. Always set for standalone memos.
    var categoryID: String?
    /// Instant on the timeline the memo belongs to, which is not necessarily
    /// when it was typed: a note added to yesterday stays on yesterday.
    var occurredAt: Date
    /// Optional map position. Existing timeline-only memos keep this nil.
    var mapPoint: GeoPoint?
    /// 시간을 지정하지 않은 메모. nil·false는 시간이 있는 메모(예전 기록 포함).
    var isTimeless: Bool?
    /// 스티커 정보. nil이면 일반 메모다. 메모 하나가 스티커 정보를 함께 가진다(예전 기록은 nil).
    var stickerSymbol: String? = nil
    var stickerColorHex: String? = nil
    var kind: MemoKind
    var text: String
    var attachments: [MemoAttachment]
    var isHighlightedInReview: Bool
    var createdAt: Date
    var updatedAt: Date

    var isSticker: Bool { stickerSymbol != nil }

    init(
        id: UUID = UUID(),
        planID: UUID? = nil,
        targetID: String? = nil,
        categoryID: String? = nil,
        occurredAt: Date? = nil,
        mapPoint: GeoPoint? = nil,
        isTimeless: Bool? = nil,
        kind: MemoKind,
        text: String,
        attachments: [MemoAttachment] = [],
        isHighlightedInReview: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.planID = planID
        self.targetID = targetID
        self.categoryID = categoryID
        self.occurredAt = occurredAt ?? createdAt
        self.mapPoint = mapPoint
        self.isTimeless = isTimeless
        self.kind = kind
        self.text = text
        self.attachments = attachments
        self.isHighlightedInReview = isHighlightedInReview
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, planID, targetID, categoryID, occurredAt, mapPoint, isTimeless, kind, text
        case attachments, isHighlightedInReview, createdAt, updatedAt
        case stickerSymbol, stickerColorHex
    }

    /// `categoryID` and `occurredAt` arrived after the first archive format,
    /// so records saved by older builds decode with their plan-derived values.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        stickerSymbol = try values.decodeIfPresent(String.self, forKey: .stickerSymbol)
        stickerColorHex = try values.decodeIfPresent(String.self, forKey: .stickerColorHex)
        planID = try values.decodeIfPresent(UUID.self, forKey: .planID)
        targetID = try values.decodeIfPresent(String.self, forKey: .targetID)
        categoryID = try values.decodeIfPresent(String.self, forKey: .categoryID)
        kind = try values.decode(MemoKind.self, forKey: .kind)
        text = try values.decode(String.self, forKey: .text)
        attachments = try values.decodeIfPresent(
            [MemoAttachment].self,
            forKey: .attachments
        ) ?? []
        isHighlightedInReview = try values.decodeIfPresent(
            Bool.self,
            forKey: .isHighlightedInReview
        ) ?? true
        let decodedCreatedAt = try values.decodeIfPresent(
            Date.self,
            forKey: .createdAt
        ) ?? .now
        createdAt = decodedCreatedAt
        updatedAt = try values.decodeIfPresent(
            Date.self,
            forKey: .updatedAt
        ) ?? decodedCreatedAt
        occurredAt = try values.decodeIfPresent(
            Date.self,
            forKey: .occurredAt
        ) ?? decodedCreatedAt
        mapPoint = try values.decodeIfPresent(
            GeoPoint.self,
            forKey: .mapPoint
        )
        isTimeless = try values.decodeIfPresent(Bool.self, forKey: .isTimeless)
    }
}
