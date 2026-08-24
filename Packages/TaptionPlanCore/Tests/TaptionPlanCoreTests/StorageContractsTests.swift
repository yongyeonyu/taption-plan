import Foundation
import XCTest
@testable import TaptionPlanCore

final class StorageContractsTests: XCTestCase {
    func testEnvelopeSeparatesV2StorageDomains() throws {
        let memo = try TaptionPlanMemoRecord(
            occurredAt: Date(timeIntervalSince1970: 100),
            text: "점심",
            locationContext: .init(
                capturedAt: Date(timeIntervalSince1970: 101),
                latitude: 37.5,
                longitude: 126.9
            ),
            weatherContext: .init(
                capturedAt: Date(timeIntervalSince1970: 102),
                conditionCode: "sunny",
                temperatureCelsius: 25
            )
        )
        let account = TaptionPlanExternalCalendarAccountIdentity(
            provider: .apple,
            accountID: "account-1"
        )
        let calendar = TaptionPlanExternalCalendarIdentity(
            account: account,
            calendarID: "calendar-1"
        )
        let media = TaptionPlanMediaReference(localIdentifier: "photos-asset-1")
        let envelope = try TaptionPlanStorageEnvelopeV2(
            userContent: .init(memos: [memo]),
            externalCalendarPreferences: .init(
                preferredProvider: .apple,
                selectedCalendars: [calendar]
            ),
            mediaReferences: [media],
            contentLinks: [
                .init(from: .memo(memo.id), to: .media(media.id)),
            ]
        )

        let data = try JSONEncoder().encode(envelope)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertNotNil(object["userContent"])
        XCTAssertNotNil(object["externalCalendarPreferences"])
        XCTAssertNotNil(object["mediaReferences"])
        XCTAssertNotNil(object["contentLinks"])
        XCTAssertNil(object["calendarEvents"])
        XCTAssertNil(object["photos"])
        XCTAssertFalse(
            String(decoding: data, as: UTF8.self).contains("event-1")
        )
    }

    func testV1IsRejectedWithoutCompatibilityFallback() throws {
        let data = Data("{\"schemaVersion\":1}".utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(TaptionPlanStorageEnvelopeV2.self, from: data)) { error in
            XCTAssertEqual(error as? TaptionPlanStorageError, .unsupportedSchema(1))
        }
    }

    func testMemoStorageRejectsMoreThan1000Characters() throws {
        let text = String(repeating: "가", count: 1_001)

        XCTAssertThrowsError(
            try TaptionPlanMemoRecord(occurredAt: .now, text: text)
        ) { error in
            XCTAssertEqual(
                error as? TaptionPlanMemoStorageError,
                .textExceedsLimit(actual: 1_001, maximum: 1_000)
            )
        }
    }

    func testMemoStorageRejectsWhitespaceOnlyText() {
        XCTAssertThrowsError(
            try TaptionPlanMemoRecord(occurredAt: .now, text: "  \n ")
        ) { error in
            XCTAssertEqual(
                error as? TaptionPlanMemoStorageError,
                .textIsEmpty
            )
        }
    }

    func testMemoStoreValidatesReplacementAtStorageBoundary() throws {
        let location = TaptionPlanMemoLocationContext(
            capturedAt: .now,
            latitude: 37.5,
            longitude: 126.9
        )
        let weather = TaptionPlanMemoWeatherContext(
            capturedAt: .now,
            conditionCode: "clear",
            temperatureCelsius: 24
        )
        let memo = try TaptionPlanMemoRecord(
            occurredAt: .now,
            text: "원본",
            locationContext: location,
            weatherContext: weather
        )
        var store = TaptionPlanMemoStore(records: [memo])

        XCTAssertThrowsError(
            try store.replaceText(
                for: memo.id,
                with: String(repeating: "a", count: 1_001)
            )
        )
        XCTAssertEqual(store.records[0].text, "원본")

        try store.replaceText(for: memo.id, with: "수정")
        XCTAssertEqual(store.records[0].text, "수정")
        XCTAssertEqual(store.records[0].locationContext, location)
        XCTAssertEqual(store.records[0].weatherContext, weather)
    }

    func testExternalCalendarProjectionIsTransient() throws {
        let account = TaptionPlanExternalCalendarAccountIdentity(
            provider: .google,
            accountID: "google-account"
        )
        let calendar = TaptionPlanExternalCalendarIdentity(
            account: account,
            calendarID: "calendar"
        )
        let identity = TaptionPlanExternalCalendarEventIdentity(
            calendar: calendar,
            eventID: "event"
        )
        let projection = TaptionPlanExternalCalendarEventProjection(
            identity: identity,
            title: "외부 일정",
            startsAt: .now,
            endsAt: .now.addingTimeInterval(3_600)
        )

        XCTAssertFalse(TaptionPlanExternalCalendarEventProjection.isPersisted)
        XCTAssertEqual(projection.identity, identity)
        XCTAssertEqual(projection.title, "외부 일정")
    }

    func testMediaReferenceContainsOnlyPhotosIdentityAndContentLinkRoundTrips() throws {
        let media = TaptionPlanMediaReference(
            localIdentifier: "asset-local-id",
            capturedAt: Date(timeIntervalSince1970: 42)
        )
        let memoID = UUID()
        let envelope = try TaptionPlanStorageEnvelopeV2(
            mediaReferences: [media],
            contentLinks: [.init(from: .memo(memoID), to: .media(media.id))]
        )
        let decoded = try JSONDecoder().decode(
            TaptionPlanStorageEnvelopeV2.self,
            from: JSONEncoder().encode(envelope)
        )

        XCTAssertEqual(decoded.mediaReferences, [media])
        XCTAssertEqual(decoded.contentLinks, envelope.contentLinks)
        let json = String(decoding: try JSONEncoder().encode(media), as: UTF8.self)
        XCTAssertFalse(json.contains("originalData"))
        XCTAssertFalse(json.contains("originalURL"))
    }
}
