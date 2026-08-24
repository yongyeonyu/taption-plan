import Foundation

public enum TaptionPlanMemoStorageError: Error, Equatable, Sendable {
    case textIsEmpty
    case textExceedsLimit(actual: Int, maximum: Int)
}

public struct TaptionPlanMemoLocationContext: Codable, Hashable, Sendable {
    public let capturedAt: Date
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracyMeters: Double?
    public let placeName: String?

    public init(
        capturedAt: Date,
        latitude: Double,
        longitude: Double,
        horizontalAccuracyMeters: Double? = nil,
        placeName: String? = nil
    ) {
        self.capturedAt = capturedAt
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.placeName = placeName
    }
}

public struct TaptionPlanMemoWeatherContext: Codable, Hashable, Sendable {
    public let capturedAt: Date
    public let conditionCode: String
    public let temperatureCelsius: Double
    public let airQualityIndex: Int?

    public init(
        capturedAt: Date,
        conditionCode: String,
        temperatureCelsius: Double,
        airQualityIndex: Int? = nil
    ) {
        self.capturedAt = capturedAt
        self.conditionCode = conditionCode
        self.temperatureCelsius = temperatureCelsius
        self.airQualityIndex = airQualityIndex
    }
}

public struct TaptionPlanMemoRecord: Codable, Hashable, Sendable {
    public static let maximumTextLength = 1_000

    public let id: UUID
    public let occurredAt: Date
    public let text: String
    public let locationContext: TaptionPlanMemoLocationContext?
    public let weatherContext: TaptionPlanMemoWeatherContext?
    public let mediaReferenceIDs: [String]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        occurredAt: Date,
        text: String,
        locationContext: TaptionPlanMemoLocationContext? = nil,
        weatherContext: TaptionPlanMemoWeatherContext? = nil,
        mediaReferenceIDs: [String] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) throws {
        try Self.validate(text: text)
        self.id = id
        self.occurredAt = occurredAt
        self.text = text
        self.locationContext = locationContext
        self.weatherContext = weatherContext
        self.mediaReferenceIDs = mediaReferenceIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func replacingText(_ text: String, at date: Date = .now) throws -> Self {
        try Self(
            id: id,
            occurredAt: occurredAt,
            text: text,
            locationContext: locationContext,
            weatherContext: weatherContext,
            mediaReferenceIDs: mediaReferenceIDs,
            createdAt: createdAt,
            updatedAt: date
        )
    }

    public static func validate(text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaptionPlanMemoStorageError.textIsEmpty
        }
        guard text.count <= maximumTextLength else {
            throw TaptionPlanMemoStorageError.textExceedsLimit(
                actual: text.count,
                maximum: maximumTextLength
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case occurredAt
        case text
        case locationContext
        case weatherContext
        case mediaReferenceIDs
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(UUID.self, forKey: .id),
            occurredAt: values.decode(Date.self, forKey: .occurredAt),
            text: values.decode(String.self, forKey: .text),
            locationContext: values.decodeIfPresent(
                TaptionPlanMemoLocationContext.self,
                forKey: .locationContext
            ),
            weatherContext: values.decodeIfPresent(
                TaptionPlanMemoWeatherContext.self,
                forKey: .weatherContext
            ),
            mediaReferenceIDs: values.decodeIfPresent(
                [String].self,
                forKey: .mediaReferenceIDs
            ) ?? [],
            createdAt: values.decode(Date.self, forKey: .createdAt),
            updatedAt: values.decode(Date.self, forKey: .updatedAt)
        )
    }
}

public struct TaptionPlanMemoStore: Sendable {
    public private(set) var records: [TaptionPlanMemoRecord]

    public init(records: [TaptionPlanMemoRecord] = []) {
        self.records = records
    }

    public mutating func insert(_ record: TaptionPlanMemoRecord) {
        records.append(record)
    }

    public mutating func replaceText(
        for id: UUID,
        with text: String,
        at date: Date = .now
    ) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index] = try records[index].replacingText(text, at: date)
    }
}

public enum TaptionPlanExternalCalendarProvider: String, Codable, Hashable, Sendable {
    case apple
    case google
    case naver
}

public struct TaptionPlanExternalCalendarAccountIdentity: Codable, Hashable, Sendable {
    public let provider: TaptionPlanExternalCalendarProvider
    public let accountID: String

    public init(
        provider: TaptionPlanExternalCalendarProvider,
        accountID: String
    ) {
        self.provider = provider
        self.accountID = accountID
    }
}

public struct TaptionPlanExternalCalendarIdentity: Codable, Hashable, Sendable {
    public let account: TaptionPlanExternalCalendarAccountIdentity
    public let calendarID: String

    public init(
        account: TaptionPlanExternalCalendarAccountIdentity,
        calendarID: String
    ) {
        self.account = account
        self.calendarID = calendarID
    }
}

public struct TaptionPlanExternalCalendarEventIdentity: Codable, Hashable, Sendable {
    public let calendar: TaptionPlanExternalCalendarIdentity
    public let eventID: String

    public init(
        calendar: TaptionPlanExternalCalendarIdentity,
        eventID: String
    ) {
        self.calendar = calendar
        self.eventID = eventID
    }
}

public struct TaptionPlanExternalCalendarPreferences: Codable, Hashable, Sendable {
    public let preferredProvider: TaptionPlanExternalCalendarProvider?
    public let selectedCalendars: [TaptionPlanExternalCalendarIdentity]

    public init(
        preferredProvider: TaptionPlanExternalCalendarProvider? = nil,
        selectedCalendars: [TaptionPlanExternalCalendarIdentity] = []
    ) {
        self.preferredProvider = preferredProvider
        self.selectedCalendars = selectedCalendars
    }
}

/// A transient event projection. It deliberately has no Codable conformance;
/// only provider identities and user preferences belong in the storage envelope.
public struct TaptionPlanExternalCalendarEventProjection: Hashable, Sendable {
    public static let isPersisted = false

    public let identity: TaptionPlanExternalCalendarEventIdentity
    public let title: String
    public let startsAt: Date
    public let endsAt: Date
    public let location: String?

    public init(
        identity: TaptionPlanExternalCalendarEventIdentity,
        title: String,
        startsAt: Date,
        endsAt: Date,
        location: String? = nil
    ) {
        self.identity = identity
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.location = location
    }
}

public enum TaptionPlanMediaReferenceSource: String, Codable, Hashable, Sendable {
    case photos
}

/// A Photos asset reference only. The original image bytes and URL are never
/// part of this contract.
public struct TaptionPlanMediaReference: Codable, Hashable, Sendable {
    public let id: String
    public let source: TaptionPlanMediaReferenceSource
    public let localIdentifier: String
    public let capturedAt: Date?

    public init(
        id: String? = nil,
        source: TaptionPlanMediaReferenceSource = .photos,
        localIdentifier: String,
        capturedAt: Date? = nil
    ) {
        self.id = id ?? localIdentifier
        self.source = source
        self.localIdentifier = localIdentifier
        self.capturedAt = capturedAt
    }
}

public enum TaptionPlanContentNode: Codable, Hashable, Sendable {
    case memo(UUID)
    case media(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case id
    }

    private enum NodeType: String, Codable {
        case memo
        case media
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .memo(let id):
            try container.encode(NodeType.memo, forKey: .type)
            try container.encode(id, forKey: .id)
        case .media(let id):
            try container.encode(NodeType.media, forKey: .type)
            try container.encode(id, forKey: .id)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(NodeType.self, forKey: .type) {
        case .memo:
            self = .memo(try container.decode(UUID.self, forKey: .id))
        case .media:
            self = .media(try container.decode(String.self, forKey: .id))
        }
    }
}

public struct TaptionPlanContentLink: Codable, Hashable, Sendable {
    public let id: UUID
    public let from: TaptionPlanContentNode
    public let to: TaptionPlanContentNode

    public init(
        id: UUID = UUID(),
        from: TaptionPlanContentNode,
        to: TaptionPlanContentNode
    ) {
        self.id = id
        self.from = from
        self.to = to
    }
}

public struct TaptionPlanUserContent: Codable, Hashable, Sendable {
    public let memos: [TaptionPlanMemoRecord]

    public init(memos: [TaptionPlanMemoRecord] = []) {
        self.memos = memos
    }

    public func validate() throws {
        for memo in memos {
            try TaptionPlanMemoRecord.validate(text: memo.text)
        }
    }
}

public enum TaptionPlanStorageError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
}

public struct TaptionPlanStorageEnvelopeV2: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let updatedAt: Date
    public let userContent: TaptionPlanUserContent
    public let externalCalendarPreferences: TaptionPlanExternalCalendarPreferences
    public let mediaReferences: [TaptionPlanMediaReference]
    public let contentLinks: [TaptionPlanContentLink]

    public init(
        updatedAt: Date = .now,
        userContent: TaptionPlanUserContent = .init(),
        externalCalendarPreferences: TaptionPlanExternalCalendarPreferences = .init(),
        mediaReferences: [TaptionPlanMediaReference] = [],
        contentLinks: [TaptionPlanContentLink] = []
    ) throws {
        try userContent.validate()
        self.schemaVersion = Self.currentSchemaVersion
        self.updatedAt = updatedAt
        self.userContent = userContent
        self.externalCalendarPreferences = externalCalendarPreferences
        self.mediaReferences = mediaReferences
        self.contentLinks = contentLinks
    }

    public func validate() throws {
        try userContent.validate()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case updatedAt
        case userContent
        case externalCalendarPreferences
        case mediaReferences
        case contentLinks
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw TaptionPlanStorageError.unsupportedSchema(version)
        }
        try self.init(
            updatedAt: values.decode(Date.self, forKey: .updatedAt),
            userContent: values.decode(TaptionPlanUserContent.self, forKey: .userContent),
            externalCalendarPreferences: values.decode(
                TaptionPlanExternalCalendarPreferences.self,
                forKey: .externalCalendarPreferences
            ),
            mediaReferences: values.decode(
                [TaptionPlanMediaReference].self,
                forKey: .mediaReferences
            ),
            contentLinks: values.decode(
                [TaptionPlanContentLink].self,
                forKey: .contentLinks
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(userContent, forKey: .userContent)
        try values.encode(
            externalCalendarPreferences,
            forKey: .externalCalendarPreferences
        )
        try values.encode(mediaReferences, forKey: .mediaReferences)
        try values.encode(contentLinks, forKey: .contentLinks)
    }
}
