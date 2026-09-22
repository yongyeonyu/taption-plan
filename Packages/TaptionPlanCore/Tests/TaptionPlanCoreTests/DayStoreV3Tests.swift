import Foundation
import XCTest
import CSQLite
@testable import TaptionPlanCore

private actor ConcurrentOpenBarrier {
    private var waiting: CheckedContinuation<Void, Never>?

    func waitForPeer() async {
        guard let waiting else {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.waiting = continuation
            }
            return
        }
        self.waiting = nil
        waiting.resume()
    }
}

final class DayStoreV3Tests: XCTestCase {
    func testConcurrentColdOpensInitializeOneV3Schema() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let start = ConcurrentOpenBarrier()
        let firstOpen = Task.detached {
            await start.waitForPeer()
            return try TaptionPlanV3Store(url: url, device: .iPhone)
        }
        let secondOpen = Task.detached {
            await start.waitForPeer()
            return try TaptionPlanV3Store(url: url, device: .iPhone)
        }
        let firstResult = await firstOpen.result
        let secondResult = await secondOpen.result
        let first = try firstResult.get()
        let second = try secondResult.get()
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 21)
        let event = event(day: day, id: "cold-open", timestamp: 10)

        try await first.appendRawEvents([event])

        let events = try await second.rawEvents(for: day)
        XCTAssertEqual(events, [event])
    }

    func testMigrationMarkerRejectsEmbeddedNULForWriteAndLookup() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        _ = try await store.markMigrationCompleted("migration")

        do {
            _ = try await store.markMigrationCompleted("migration\0alias")
            XCTFail("Embedded-NUL migration keys must be rejected")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .invalidIdentifier)
        }
        do {
            _ = try await store.migrationCompleted("migration\0alias")
            XCTFail("Embedded-NUL migration lookups must be rejected")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .invalidIdentifier)
        }

        let validMarkerRemains = try await store.migrationCompleted("migration")
        XCTAssertTrue(validMarkerRemains)
    }

    func testStorageRejectsInvalidDayKeyBeforeRawWriteOrRead() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let invalidDay = TaptionPlanDayKey(year: 0, month: 0, day: 0)

        do {
            try await store.appendRawEvents([
                event(day: invalidDay, id: "invalid-day", timestamp: 1)
            ])
            XCTFail("Invalid storage day keys must be rejected")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .invalidDay)
        }

        do {
            _ = try await store.rawEvents(for: invalidDay)
            XCTFail("Invalid storage day keys must be rejected on reads")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .invalidDay)
        }
    }

    func testDeleteAllDataKeepsMigrationMarker() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 5)
        let raw = event(day: day, id: "gps-1", timestamp: 10)
        try await store.appendRawEvents([raw])
        try await store.appendRawEvents(
            [],
            outboxItems: [
                TaptionPlanV3OutboxItem(
                    id: "watch-item-1",
                    kind: "ambient-summary",
                    payload: Data([1])
                ),
            ]
        )
        let digest = try await store.rawDigest(for: day)
        try await store.replaceMaterializedDay(
            .init(
                device: .iPhone,
                day: day,
                sourceRevision: 1,
                projectionVersion: 1,
                rawDigest: digest.sha256,
                rawEventCount: digest.eventCount,
                firstTimestamp: digest.firstTimestamp,
                lastTimestamp: digest.lastTimestamp,
                payload: Data([3])
            )
        )
        _ = try await store.markMigrationCompleted("legacy-import")

        try await store.deleteAllData()

        let days = try await store.allDays()
        let events = try await store.rawEvents(for: day)
        let materialized = try await store.materializedDay(for: day)
        let migrationCompleted = try await store.migrationCompleted(
            "legacy-import"
        )
        XCTAssertTrue(days.isEmpty)
        XCTAssertTrue(events.isEmpty)
        let outbox = try await store.pendingOutboxItems()
        XCTAssertTrue(outbox.isEmpty)
        XCTAssertNil(materialized)
        XCTAssertTrue(migrationCompleted)
    }

    func testDateQueryUsesDayLeadingIndex() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 30)
        try await store.appendRawEvents([
            event(day: day, id: "gps-1", timestamp: 10)
        ])

        let plan = try await store.explainRawDayQuery()

        XCTAssertTrue(
            plan.contains { $0.contains("raw_events_day_time_index") },
            "Expected date lookup to use the day-leading index: \(plan)"
        )
    }

    func testRawAppendIsIdempotentAndRejectsConflictingPayload() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 30)
        let original = event(day: day, id: "stable-1", timestamp: 20, payload: Data([1]))

        try await store.validateRawEventsForAppend([original])
        let eventsBeforeAppend = try await store.rawEvents(for: day)
        XCTAssertTrue(eventsBeforeAppend.isEmpty)
        try await store.appendRawEvents([original, original])
        let initialEvents = try await store.rawEvents(for: day)
        XCTAssertEqual(initialEvents, [original])
        let initialDigest = try await store.rawDigest(for: day)
        let initialCacheCount = await store.rawDigestCacheCount
        XCTAssertEqual(initialCacheCount, 1)

        let duplicateReceipt = try await store.appendRawEvents([original])
        XCTAssertTrue(duplicateReceipt.isEmpty)
        let duplicateCacheCount = await store.rawDigestCacheCount
        let duplicateDigest = try await store.rawDigest(for: day)
        XCTAssertEqual(duplicateCacheCount, 1)
        XCTAssertEqual(duplicateDigest, initialDigest)

        var conflicting = original
        conflicting = TaptionPlanRawEvent(
            device: conflicting.device,
            day: conflicting.day,
            timestamp: conflicting.timestamp,
            sequence: conflicting.sequence,
            id: conflicting.id,
            domain: conflicting.domain,
            provenance: conflicting.provenance,
            payload: Data([2])
        )
        do {
            try await store.validateRawEventsForAppend([conflicting])
            XCTFail("Expected validation conflict")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(
                error,
                .payloadConflict(device: .iPhone, domain: "gps", id: "stable-1")
            )
        }
        do {
            try await store.appendRawEvents([conflicting])
            XCTFail("Expected append-only conflict")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(
                error,
                .payloadConflict(device: .iPhone, domain: "gps", id: "stable-1")
            )
        }
        let finalEvents = try await store.rawEvents(for: day)
        XCTAssertEqual(finalEvents, [original])
    }

    func testRawEventPagesVisitStableOrderAndRespectDomain() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let firstDay = TaptionPlanDayKey(year: 2026, month: 9, day: 1)
        let secondDay = TaptionPlanDayKey(year: 2026, month: 9, day: 2)
        let thirdDay = TaptionPlanDayKey(year: 2026, month: 9, day: 3)
        let expected = [
            event(day: firstDay, id: "gps-a", timestamp: 10),
            event(day: firstDay, id: "gps-b", timestamp: 20),
            event(day: firstDay, id: "gps-c", timestamp: 20),
            event(day: secondDay, id: "gps-d", timestamp: 5),
        ]
        let otherDomain = TaptionPlanRawEvent(
            device: .iPhone,
            day: thirdDay,
            timestamp: Date(timeIntervalSince1970: 15),
            sequence: 15,
            id: "ambient-a",
            domain: "ambient",
            provenance: ["test-source"],
            payload: Data([8])
        )
        try await store.appendRawEvents(expected + [otherDomain])

        let firstPage = try await store.rawEventPage(limit: 2)
        XCTAssertEqual(firstPage.events, Array(expected.prefix(2)))
        XCTAssertTrue(firstPage.hasMore)
        XCTAssertEqual(firstPage.nextCursor?.id, expected[1].id)
        XCTAssertEqual(firstPage.nextCursor?.domain, expected[1].domain)

        let secondPage = try await store.rawEventPage(
            after: firstPage.nextCursor,
            limit: 2
        )
        XCTAssertEqual(secondPage.events, Array(expected.suffix(2)))
        XCTAssertTrue(secondPage.hasMore)

        let thirdPage = try await store.rawEventPage(
            after: secondPage.nextCursor,
            limit: 2
        )
        XCTAssertEqual(thirdPage.events, [otherDomain])
        XCTAssertFalse(thirdPage.hasMore)
        XCTAssertEqual(thirdPage.nextCursor?.id, otherDomain.id)
        XCTAssertEqual(thirdPage.nextCursor?.domain, otherDomain.domain)

        let ambientPage = try await store.rawEventPage(domain: "ambient", limit: 10)
        XCTAssertEqual(ambientPage.events, [otherDomain])
        XCTAssertFalse(ambientPage.hasMore)

        do {
            _ = try await store.rawEventPage(
                after: TaptionPlanRawEventCursor(after: otherDomain),
                domain: "gps"
            )
            XCTFail("Expected cursor-domain mismatch")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .invalidDomain)
        }
    }

    func testLatestRawEventUsesIdentifierPrefixAcrossDaysAndRevisions()
        async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let firstDay = TaptionPlanDayKey(year: 2026, month: 9, day: 1)
        let secondDay = TaptionPlanDayKey(year: 2026, month: 9, day: 2)
        let thirdDay = TaptionPlanDayKey(year: 2026, month: 9, day: 3)
        let prefix = "00000000-0000-0000-0000-000000000001:"
        let neighboringPrefix = "00000000-0000-0000-0000-000000000002:"

        func summaryEvent(
            _ id: String,
            sequence: UInt64,
            day: TaptionPlanDayKey,
            domain: String = "watch-sensor-summary",
            timestamp: TimeInterval
        ) -> TaptionPlanRawEvent {
            TaptionPlanRawEvent(
                device: .iPhone,
                day: day,
                timestamp: Date(timeIntervalSince1970: timestamp),
                sequence: sequence,
                id: id,
                domain: domain,
                provenance: ["test-source"],
                payload: Data([7])
            )
        }

        let events = [
            summaryEvent(prefix + "8", sequence: 8, day: firstDay, timestamp: 30),
            summaryEvent(prefix + "10", sequence: 10, day: thirdDay, timestamp: 1),
            summaryEvent(prefix + "10:r9", sequence: 10, day: firstDay, timestamp: 2),
            summaryEvent(prefix + "10:r12", sequence: 10, day: secondDay, timestamp: 3),
            summaryEvent(
                neighboringPrefix + "9999",
                sequence: 9_999,
                day: thirdDay,
                timestamp: 99
            ),
            summaryEvent(
                prefix + "10000",
                sequence: 10_000,
                day: thirdDay,
                domain: "other-domain",
                timestamp: 100
            ),
        ]
        try await store.appendRawEvents(events)

        let latest = try await store.latestRawEvent(
            domain: "watch-sensor-summary",
            idPrefix: prefix
        )
        XCTAssertEqual(latest?.id, prefix + "10:r12")
        XCTAssertEqual(latest?.sequence, 10)
        XCTAssertEqual(latest?.day, secondDay)

        do {
            _ = try await store.latestRawEvent(
                domain: "watch-sensor-summary",
                idPrefix: "é:"
            )
            XCTFail("A non-ASCII identifier prefix must be rejected")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .invalidIdentifier)
        }
    }

    func testLatestRawEventAcceptsTildeIdentifierPrefix() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 4)
        let expected = event(day: day, id: "~:summary:42", timestamp: 42)
        try await store.appendRawEvents([expected])

        let latest = try await store.latestRawEvent(
            domain: "gps",
            idPrefix: "~"
        )

        XCTAssertEqual(latest, expected)
    }

    func testRawEventPageClampsRequestedSize() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 1)
        let events = (0...TaptionPlanV3Store.maximumRawEventPageSize).map { index in
            event(day: day, id: "gps-\(index)", timestamp: TimeInterval(index))
        }
        try await store.appendRawEvents(events)

        let firstPage = try await store.rawEventPage(limit: Int.max)
        XCTAssertEqual(
            firstPage.events.count,
            TaptionPlanV3Store.maximumRawEventPageSize
        )
        XCTAssertTrue(firstPage.hasMore)

        let lastPage = try await store.rawEventPage(after: firstPage.nextCursor, limit: 0)
        XCTAssertEqual(lastPage.events.count, 1)
        XCTAssertFalse(lastPage.hasMore)
    }

    func testRawEventPageByteLimitSplitsAndContinues() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 1)
        let events = [
            event(
                day: day,
                id: "gps-a",
                timestamp: 1,
                payload: Data(repeating: 1, count: 64)
            ),
            event(
                day: day,
                id: "gps-b",
                timestamp: 2,
                payload: Data(repeating: 2, count: 64)
            ),
        ]
        try await store.appendRawEvents(events)

        let firstPage = try await store.rawEventPage(limit: 10, byteLimit: 220)
        XCTAssertEqual(firstPage.events, [events[0]])
        XCTAssertTrue(firstPage.hasMore)

        let secondPage = try await store.rawEventPage(
            after: firstPage.nextCursor,
            limit: 10,
            byteLimit: 220
        )
        XCTAssertEqual(secondPage.events, [events[1]])
        XCTAssertFalse(secondPage.hasMore)
    }

    func testRawEventPageRejectsSingleOversizedItemBeforeReadingPayload() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 1)
        try await store.appendRawEvents([
            event(
                day: day,
                id: "gps-large",
                timestamp: 1,
                payload: Data(repeating: 7, count: 256)
            ),
        ])

        do {
            _ = try await store.rawEventPage(byteLimit: 128)
            XCTFail("An event larger than the byte budget must not be read")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .rawEventPageItemTooLarge(limit: 128))
        }
    }

    func testRawEventPageRejectsSameConnectionWriteBetweenPages() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 1)
        try await store.appendRawEvents([
            event(day: day, id: "gps-a", timestamp: 1),
            event(day: day, id: "gps-b", timestamp: 2),
        ])
        let firstPage = try await store.rawEventPage(limit: 1)
        try await store.appendRawEvents([
            event(day: day, id: "gps-before", timestamp: 0),
        ])

        do {
            _ = try await store.rawEventPage(after: firstPage.nextCursor)
            XCTFail("A cursor must not continue after its store changed")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .staleRawEventCursor)
        }
    }

    func testRawEventPageRejectsOtherConnectionInsertReplaceAndDelete() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let otherStore = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 1)
        try await store.appendRawEvents([
            event(day: day, id: "gps-a", timestamp: 1),
            event(day: day, id: "gps-b", timestamp: 2),
            event(day: day, id: "gps-c", timestamp: 3),
        ])

        let beforeInsert = try await store.rawEventPage(limit: 1)
        try await otherStore.appendRawEvents([
            event(day: day, id: "gps-before", timestamp: 0),
        ])
        do {
            _ = try await store.rawEventPage(after: beforeInsert.nextCursor)
            XCTFail("A cursor must not continue after another connection inserts")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .staleRawEventCursor)
        }

        let beforeReplace = try await store.rawEventPage(limit: 1)
        let replacement = event(day: day, id: "gps-replaced", timestamp: 0.5)
        try await otherStore.replaceRawEvents(
            [replacement],
            for: day,
            domains: ["gps"]
        )
        do {
            _ = try await store.rawEventPage(after: beforeReplace.nextCursor)
            XCTFail("A cursor must not continue after another connection replaces")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .staleRawEventCursor)
        }

        let beforeDelete = try await store.rawEventPage(limit: 1)
        try await otherStore.deleteRawEvents(
            ids: [replacement.id],
            domain: "gps"
        )
        do {
            _ = try await store.rawEventPage(after: beforeDelete.nextCursor)
            XCTFail("A cursor must not continue after another connection deletes")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .staleRawEventCursor)
        }
    }

    func testRawEventPageRejectsSequenceOutsideSQLiteIntegerRange() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let event = TaptionPlanRawEvent(
            device: .iPhone,
            day: TaptionPlanDayKey(year: 2026, month: 9, day: 1),
            timestamp: Date(timeIntervalSince1970: 1),
            sequence: UInt64.max,
            id: "gps-overflow",
            domain: "gps",
            provenance: [],
            payload: Data()
        )

        do {
            _ = try await store.rawEventPage(
                after: TaptionPlanRawEventCursor(after: event)
            )
            XCTFail("Expected cursor sequence overflow")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .integerOverflow)
        }
    }

    func testRawEventCursorHashingUsesByteExactTextIdentity() {
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 1)
        let composed = event(day: day, id: "caf\u{00E9}", timestamp: 1)
        let decomposed = event(day: day, id: "cafe\u{0301}", timestamp: 1)
        let cursors = Set([
            TaptionPlanRawEventCursor(after: composed),
            TaptionPlanRawEventCursor(after: decomposed),
        ])

        XCTAssertEqual(cursors.count, 2)
    }

    func testOutboxIsFIFODeviceScopedAndAcknowledgedSelectively() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let watchStore = try TaptionPlanV3Store(url: url, device: .appleWatch)
        let first = TaptionPlanV3OutboxItem(
            id: "ambient-1",
            kind: "summary",
            payload: Data([1])
        )
        let second = TaptionPlanV3OutboxItem(
            id: "ambient-2",
            kind: "chunk",
            payload: Data([2])
        )
        let third = TaptionPlanV3OutboxItem(
            id: "ambient-3",
            kind: "summary",
            payload: Data([3])
        )

        try await watchStore.appendRawEvents(
            [],
            outboxItems: [first, second, third, second]
        )
        let firstPage = try await watchStore.pendingOutboxItems(limit: 2)
        XCTAssertEqual(firstPage, [first, second])

        let reopened = try TaptionPlanV3Store(url: url, device: .appleWatch)
        let persisted = try await reopened.pendingOutboxItems()
        XCTAssertEqual(persisted, [first, second, third])

        let phoneStore = try TaptionPlanV3Store(url: url, device: .iPhone)
        let phoneOutbox = try await phoneStore.pendingOutboxItems()
        XCTAssertTrue(phoneOutbox.isEmpty)

        try await reopened.deleteOutboxItems(ids: [second.id, "unknown"])
        let remaining = try await reopened.pendingOutboxItems()
        XCTAssertEqual(remaining, [first, third])
    }

    func testOutboxReenqueueIsIdempotentAndRejectsDifferentPayload() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .appleWatch)
        let item = TaptionPlanV3OutboxItem(
            id: "ambient-1",
            kind: "summary",
            payload: Data([1, 2, 3])
        )

        try await store.appendRawEvents([], outboxItems: [item, item])
        try await store.appendRawEvents([], outboxItems: [item])
        let persisted = try await store.pendingOutboxItems()
        XCTAssertEqual(persisted, [item])

        let conflict = TaptionPlanV3OutboxItem(
            id: item.id,
            kind: item.kind,
            payload: Data([9])
        )
        do {
            try await store.appendRawEvents([], outboxItems: [conflict])
            XCTFail("Expected conflicting outbox payload to be rejected")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .outboxConflict(id: item.id))
        }
        let finalItems = try await store.pendingOutboxItems()
        XCTAssertEqual(finalItems, [item])
    }

    func testOutboxAppendRollsBackWhenRawEventConflicts() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .appleWatch)
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 30)
        let original = TaptionPlanRawEvent(
            device: .appleWatch,
            day: day,
            timestamp: Date(timeIntervalSince1970: 10),
            sequence: 1,
            id: "ambient-raw-1",
            domain: "watch-sensor-summary",
            provenance: ["test"],
            payload: Data([1])
        )
        try await store.appendRawEvents([original])
        let conflicting = TaptionPlanRawEvent(
            device: original.device,
            day: original.day,
            timestamp: original.timestamp,
            sequence: original.sequence,
            id: original.id,
            domain: original.domain,
            provenance: original.provenance,
            payload: Data([2])
        )
        let outboxItem = TaptionPlanV3OutboxItem(
            id: "ambient-transfer-1",
            kind: "summary",
            payload: Data([3])
        )

        do {
            try await store.appendRawEvents(
                [conflicting],
                outboxItems: [outboxItem]
            )
            XCTFail("Expected raw event conflict")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(
                error,
                .payloadConflict(
                    device: .appleWatch,
                    domain: original.domain,
                    id: original.id
                )
            )
        }

        let rawEvents = try await store.rawEvents(for: day)
        let pendingOutbox = try await store.pendingOutboxItems()
        XCTAssertEqual(rawEvents, [original])
        XCTAssertTrue(pendingOutbox.isEmpty)
    }

    func testOutboxLimitRejectsBatchWithoutPartialInsert() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .appleWatch)
        let items = (0...4_096).map { index in
            TaptionPlanV3OutboxItem(
                id: "ambient-\(index)",
                kind: "summary",
                payload: Data([1])
            )
        }

        do {
            try await store.appendRawEvents([], outboxItems: items)
            XCTFail("Expected the bounded outbox to reject an oversized batch")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .outboxLimitExceeded(limit: 4_096))
        }

        let pending = try await store.pendingOutboxItems()
        XCTAssertTrue(pending.isEmpty)

        do {
            try await store.appendRawEvents(
                [],
                outboxItems: [
                    TaptionPlanV3OutboxItem(
                        id: "oversized",
                        kind: "summary",
                        payload: Data(repeating: 1, count: 4 * 1_024 * 1_024 + 1)
                    ),
                ]
            )
            XCTFail("Expected an oversized transfer to be rejected")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(
                error,
                .outboxPayloadTooLarge(limit: 4 * 1_024 * 1_024)
            )
        }
    }

    func testConditionalRawReplacementDoesNotClobberConcurrentWriter() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 30)
        func projection(_ id: String, _ payload: UInt8) -> TaptionPlanRawEvent {
            TaptionPlanRawEvent(
                device: .iPhone,
                day: day,
                timestamp: Date(timeIntervalSince1970: 10),
                sequence: 1,
                id: id,
                domain: "plan-actual",
                provenance: ["projection:day"],
                payload: Data([payload])
            )
        }
        let original = projection("old", 1)
        let stale = projection("stale", 2)
        try await store.appendRawEvents([original])
        let didReplace = try await store.replaceRawEvents(
            [stale],
            for: day,
            domains: ["plan-actual"],
            onlyIfCurrent: [original]
        )
        XCTAssertTrue(didReplace)

        let concurrent = projection("newer", 3)
        try await store.appendRawEvents([concurrent])
        let restored = try await store.replaceRawEvents(
            [original],
            for: day,
            domains: ["plan-actual"],
            onlyIfCurrent: [stale]
        )

        XCTAssertFalse(restored)
        let persisted = try await store.rawEvents(for: day)
        XCTAssertEqual(
            Set(persisted),
            Set([stale, concurrent])
        )
    }

    func testRawEventRollbackPreservesConcurrentReplacement() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 30)
        func sensorEvent(timestamp: TimeInterval, payload: UInt8) -> TaptionPlanRawEvent {
            TaptionPlanRawEvent(
                device: .iPhone,
                day: day,
                timestamp: Date(timeIntervalSince1970: timestamp),
                sequence: UInt64(timestamp),
                id: "sensor-reading-1",
                domain: "sensor-reading",
                provenance: ["iPhone.location"],
                payload: Data([payload])
            )
        }
        let stale = sensorEvent(timestamp: 10, payload: 1)
        let concurrent = sensorEvent(timestamp: 11, payload: 2)
        try await store.appendRawEvents([stale])
        try await store.replaceRawEvents(
            [concurrent],
            for: day,
            domains: ["sensor-reading"]
        )

        let removed = try await store.removeRawEventsIfUnchanged([stale])
        let persisted = try await store.rawEvents(for: day)

        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(persisted, [concurrent])
    }

    func testRawBatchIdentityAllowsDelimiterCharactersInDomainAndID() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 5)
        let events = [
            TaptionPlanRawEvent(
                device: .iPhone,
                day: day,
                timestamp: Date(timeIntervalSince1970: 1),
                sequence: 1,
                id: "c",
                domain: "a|b",
                provenance: ["test-source"],
                payload: Data([1])
            ),
            TaptionPlanRawEvent(
                device: .iPhone,
                day: day,
                timestamp: Date(timeIntervalSince1970: 2),
                sequence: 2,
                id: "b|c",
                domain: "a",
                provenance: ["test-source"],
                payload: Data([2])
            ),
        ]

        try await store.validateRawEventsForAppend(events)
        _ = try await store.appendRawEvents(events)

        let stored = try await store.rawEvents(for: day)
        XCTAssertEqual(stored.count, 2)
    }

    func testRawEventIdentityMatchesSQLiteByteIdentity() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 20)
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        func rawEvent(id: String, domain: String) -> TaptionPlanRawEvent {
            TaptionPlanRawEvent(
                device: .iPhone,
                day: day,
                timestamp: Date(timeIntervalSince1970: 10),
                sequence: 1,
                id: id,
                domain: domain,
                provenance: ["test-source"],
                payload: Data([1])
            )
        }
        let events = [
            rawEvent(id: composed, domain: "gps"),
            rawEvent(id: decomposed, domain: "gps"),
            rawEvent(id: "same-id", domain: composed),
            rawEvent(id: "same-id", domain: decomposed),
        ]

        try await store.validateRawEventsForAppend(events)
        let receipt = try await store.appendRawEvents(events)
        let stored = try await store.rawEvents(for: day)

        XCTAssertEqual(receipt.count, 4)
        XCTAssertEqual(stored.count, 4)
        XCTAssertEqual(Set(stored).count, 4)
        XCTAssertEqual(Set(receipt.map { Data($0.id.utf8) }).count, 3)
        XCTAssertEqual(Set(receipt.map { Data($0.domain.utf8) }).count, 3)
        let composedDomainEvents = try await store.rawEvents(for: day, domain: composed)
        let decomposedDomainEvents = try await store.rawEvents(for: day, domain: decomposed)
        XCTAssertEqual(composedDomainEvents.count, 1)
        XCTAssertEqual(decomposedDomainEvents.count, 1)
        let sqlDigest = try await store.rawDigest(for: day)
        let reversedStaticDigest = TaptionPlanV3Store.digest(
            events: Array(stored.reversed()),
            device: .iPhone,
            day: day
        )
        XCTAssertEqual(reversedStaticDigest.sha256, sqlDigest.sha256)

        try await store.deleteRawEvents(
            ids: [composed, decomposed],
            domain: "gps"
        )
        let remainingGPS = try await store.rawEvents(for: day, domain: "gps")
        XCTAssertTrue(remainingGPS.isEmpty)
    }

    func testRawReplacementPreservesByteDistinctStoredDomain() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 20)
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        func rawEvent(id: String, domain: String) -> TaptionPlanRawEvent {
            TaptionPlanRawEvent(
                device: .iPhone,
                day: day,
                timestamp: Date(timeIntervalSince1970: 10),
                sequence: 1,
                id: id,
                domain: domain,
                provenance: ["test-source"],
                payload: Data([1])
            )
        }
        let oldComposed = rawEvent(id: "old-composed", domain: composed)
        let oldDecomposed = rawEvent(id: "old-decomposed", domain: decomposed)
        try await store.appendRawEvents([oldComposed, oldDecomposed])

        do {
            try await store.replaceRawEvents(
                [rawEvent(id: "wrong-domain", domain: decomposed)],
                for: day,
                domains: [composed]
            )
            XCTFail("A canonically equivalent but byte-distinct domain must not match")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .invalidDomain)
        }

        let didReplace = try await store.replaceRawEvents(
            [rawEvent(id: "replacement-composed", domain: composed)],
            for: day,
            domains: [composed],
            onlyIfCurrent: [oldComposed]
        )
        XCTAssertTrue(didReplace)

        let stored = try await store.rawEvents(for: day)
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(stored.contains {
            Data($0.id.utf8) == Data("replacement-composed".utf8)
                && Data($0.domain.utf8) == Data(composed.utf8)
        })
        XCTAssertTrue(stored.contains {
            Data($0.id.utf8) == Data("old-decomposed".utf8)
                && Data($0.domain.utf8) == Data(decomposed.utf8)
        })
    }

    func testRawReplacementRemovesBothCanonicallyEquivalentByteDistinctDomains() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 20)
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let oldEvents = [composed, decomposed].enumerated().map { index, domain in
            TaptionPlanRawEvent(
                device: .iPhone,
                day: day,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                sequence: UInt64(index + 1),
                id: "old-\(index)",
                domain: domain,
                provenance: ["test-source"],
                payload: Data([UInt8(index + 1)])
            )
        }
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        try await store.appendRawEvents(oldEvents)

        let storedBeforeReplace = try await store.rawEvents(for: day)
        XCTAssertEqual(storedBeforeReplace.count, 2)
        XCTAssertEqual(
            Set(storedBeforeReplace.map { Data($0.domain.utf8) }),
            Set([composed, decomposed].map { Data($0.utf8) })
        )

        try await store.replaceRawEvents(
            [],
            for: day,
            exactDomains: [composed, decomposed]
        )

        let storedAfterReplace = try await store.rawEvents(for: day)
        XCTAssertTrue(storedAfterReplace.isEmpty)
    }

    func testOutboxDeletionUsesByteExactIDs() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .appleWatch)
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let items = [composed, decomposed].map {
            TaptionPlanV3OutboxItem(
                id: $0,
                kind: "summary",
                payload: Data([1])
            )
        }
        try await store.appendRawEvents([], outboxItems: items)

        let beforeDelete = try await store.pendingOutboxItems()
        XCTAssertEqual(beforeDelete.count, 2)
        XCTAssertEqual(
            Set(beforeDelete.map { Data($0.id.utf8) }),
            Set(items.map { Data($0.id.utf8) })
        )

        try await store.deleteOutboxItems(ids: [composed, decomposed])

        let afterDelete = try await store.pendingOutboxItems()
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testRawEventRejectsEmbeddedNULBeforeWriteDeleteOrLookup() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 20)
        let prefix = event(day: day, id: "prefix", timestamp: 10)
        try await store.appendRawEvents([prefix])

        do {
            try await store.appendRawEvents([
                event(day: day, id: "prefix\0suffix", timestamp: 20)
            ])
            XCTFail("Expected an embedded-NUL identifier to be rejected")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .invalidIdentifier)
        }
        do {
            try await store.appendRawEvents([
                TaptionPlanRawEvent(
                    device: .iPhone,
                    day: day,
                    timestamp: Date(timeIntervalSince1970: 30),
                    sequence: 30,
                    id: "other",
                    domain: "gps\0suffix",
                    provenance: ["test-source"],
                    payload: Data([3])
                )
            ])
            XCTFail("Expected an embedded-NUL domain to be rejected")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .invalidDomain)
        }
        do {
            try await store.deleteRawEvents(ids: ["prefix\0suffix"], domain: "gps")
            XCTFail("Expected an embedded-NUL delete identifier to be rejected")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .invalidIdentifier)
        }
        do {
            try await store.deleteRawEvents(ids: ["prefix"], domain: "gps\0suffix")
            XCTFail("Expected an embedded-NUL delete domain to be rejected")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .invalidDomain)
        }
        do {
            _ = try await store.rawEvent(domain: "gps", id: "prefix\0suffix")
            XCTFail("Expected an embedded-NUL lookup identifier to be rejected")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .invalidIdentifier)
        }
        do {
            try await store.replaceRawEvents([], for: day, domains: ["gps\0suffix"])
            XCTFail("Expected an embedded-NUL replacement domain to be rejected")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(error, .invalidDomain)
        }

        let stored = try await store.rawEvents(for: day)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(Data(stored[0].id.utf8), Data("prefix".utf8))
    }

    func testOpeningStoreInvalidatesLegacyPersistedRawDigestOnce() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 5)
        let expectedEvent = event(day: day, id: "gps-1", timestamp: 1)
        let expectedDigest: TaptionPlanDayDigest
        do {
            let store = try TaptionPlanV3Store(url: url, device: .iPhone)
            try await store.appendRawEvents([expectedEvent])
            expectedDigest = try await store.rawDigest(for: day)
        }

        var legacyDatabase: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &legacyDatabase,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK,
              let database = legacyDatabase else {
            if let legacyDatabase { sqlite3_close(legacyDatabase) }
            XCTFail("Unable to reopen SQLite fixture")
            return
        }
        defer {
            if let legacyDatabase { sqlite3_close(legacyDatabase) }
        }
        let tamperStatus = sqlite3_exec(
            database,
            """
            DELETE FROM migration_markers
            WHERE key = 'raw_digest_cache_atomic_write_v1';
            UPDATE raw_digest_cache SET sha256 = 'obsolete';
            """,
            nil,
            nil,
            nil
        )
        XCTAssertEqual(tamperStatus, SQLITE_OK)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)
        legacyDatabase = nil

        let reopened = try TaptionPlanV3Store(url: url, device: .iPhone)
        let digest = try await reopened.rawDigest(for: day)

        XCTAssertEqual(digest, expectedDigest)
        let migrationMarkerApplied = try await reopened.migrationCompleted(
            "raw_digest_cache_atomic_write_v1"
        )
        XCTAssertTrue(migrationMarkerApplied)
    }

    func testRawAppendReceiptRollsBackOnlyNewEvents() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 6)
        let existing = event(day: day, id: "existing", timestamp: 10)
        let added = event(day: day, id: "added", timestamp: 20)
        try await store.appendRawEvents([existing])
        _ = try await store.rawDigest(for: day)

        let receipt = try await store.appendRawEvents([existing, added])
        XCTAssertEqual(
            receipt,
            [.init(domain: added.domain, id: added.id)]
        )
        try await store.deleteRawEvents(
            ids: receipt.map(\.id),
            domain: added.domain
        )

        let remaining = try await store.rawEvents(for: day)
        let digest = try await store.rawDigest(for: day)
        XCTAssertEqual(remaining, [existing])
        XCTAssertEqual(digest.eventCount, 1)
    }

    func testRawBatchReusesStatementsAndOptimizePreservesEvents() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 31)
        let events = (0..<1_000).map { index in
            event(
                day: day,
                id: "gps-\(index)",
                timestamp: TimeInterval(index)
            )
        }

        try await store.appendRawEvents(events + events)
        try await store.optimize()

        let loaded = try await store.rawEvents(for: day)
        XCTAssertEqual(loaded.count, events.count)
        XCTAssertEqual(loaded.first?.id, "gps-0")
        XCTAssertEqual(loaded.last?.id, "gps-999")
    }

    func testDigestIsStableBySortOrderAndIncludesProvenance() async throws {
        let firstURL = temporaryURL()
        let secondURL = temporaryURL()
        defer {
            removeDatabase(at: firstURL)
            removeDatabase(at: secondURL)
        }
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 30)
        let first = event(
            day: day,
            id: "gps-1",
            timestamp: 20,
            provenance: ["iPhone.location", "CoreMotion"]
        )
        let second = event(
            day: day,
            id: "gps-2",
            timestamp: 10,
            provenance: ["iPhone.location"]
        )
        let firstStore = try TaptionPlanV3Store(url: firstURL, device: .iPhone)
        let secondStore = try TaptionPlanV3Store(url: secondURL, device: .iPhone)
        try await firstStore.appendRawEvents([first, second])
        try await secondStore.appendRawEvents([second, first])

        let firstDigest = try await firstStore.rawDigest(for: day)
        let secondDigest = try await secondStore.rawDigest(for: day)
        XCTAssertEqual(firstDigest, secondDigest)

        let changedProvenance = TaptionPlanRawEvent(
            device: first.device,
            day: first.day,
            timestamp: first.timestamp,
            sequence: first.sequence,
            id: "gps-3",
            domain: first.domain,
            provenance: ["iPhone.location", "different-source"],
            payload: first.payload
        )
        try await firstStore.appendRawEvents([changedProvenance])
        let changedDigest = try await firstStore.rawDigest(for: day)
        XCTAssertNotEqual(firstDigest.sha256, changedDigest.sha256)
    }

    func testDigestUsesDomainAsTheFinalStableSortKey() async throws {
        let firstURL = temporaryURL()
        let secondURL = temporaryURL()
        defer {
            removeDatabase(at: firstURL)
            removeDatabase(at: secondURL)
        }
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 5)
        let gps = event(day: day, id: "shared", timestamp: 10)
        let motion = TaptionPlanRawEvent(
            device: gps.device,
            day: gps.day,
            timestamp: gps.timestamp,
            sequence: gps.sequence,
            id: gps.id,
            domain: "motion",
            provenance: gps.provenance,
            payload: Data([8])
        )
        let firstStore = try TaptionPlanV3Store(
            url: firstURL,
            device: .iPhone
        )
        let secondStore = try TaptionPlanV3Store(
            url: secondURL,
            device: .iPhone
        )
        try await firstStore.appendRawEvents([gps, motion])
        try await secondStore.appendRawEvents([motion, gps])

        let expected = TaptionPlanV3Store.digest(
            events: [motion, gps],
            device: .iPhone,
            day: day
        )
        let firstDigest = try await firstStore.rawDigest(for: day)
        let secondDigest = try await secondStore.rawDigest(for: day)
        XCTAssertEqual(firstDigest, expected)
        XCTAssertEqual(secondDigest, expected)
    }

    func testStreamingRawDigestMatchesCanonicalDigestForLargePayloads() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 4)
        let events = (0..<1_000).map { index in
            event(
                day: day,
                id: "gps-\(index)",
                timestamp: TimeInterval(index),
                payload: Data(repeating: UInt8(index % 255), count: 4_096)
            )
        }
        try await store.appendRawEvents(events)

        let digest = try await store.rawDigest(for: day)

        XCTAssertEqual(digest, TaptionPlanV3Store.digest(
            events: events,
            device: .iPhone,
            day: day
        ))
    }

    func testRawDigestCacheSeesAnotherConnectionCommit() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 5)
        let first = try TaptionPlanV3Store(url: url, device: .iPhone)
        let second = try TaptionPlanV3Store(url: url, device: .iPhone)
        try await first.appendRawEvents([
            event(day: day, id: "first", timestamp: 1),
        ])
        let cached = try await first.rawDigest(for: day)

        try await second.appendRawEvents([
            event(day: day, id: "second", timestamp: 2),
        ])

        let updated = try await first.rawDigest(for: day)
        XCTAssertNotEqual(updated, cached)
    }

    func testConcurrentDigestAndAppendLeavesCurrentPersistedDigest() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 6)
        let reader = try TaptionPlanV3Store(url: url, device: .iPhone)
        let writer = try TaptionPlanV3Store(url: url, device: .iPhone)
        let initial = event(
            day: day,
            id: "initial",
            timestamp: 1,
            payload: Data(repeating: 1, count: 256 * 1_024)
        )
        try await writer.appendRawEvents([initial])
        let appended = (0..<80).map { index in
            event(
                day: day,
                id: "concurrent-\(index)",
                timestamp: TimeInterval(index + 2)
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for event in appended {
                    try await writer.appendRawEvents([event])
                }
            }
            group.addTask {
                for _ in appended {
                    _ = try await reader.rawDigest(for: day)
                    await Task.yield()
                }
            }
            try await group.waitForAll()
        }

        let stored = try await reader.rawEvents(for: day)
        let freshReader = try TaptionPlanV3Store(url: url, device: .iPhone)
        let digest = try await freshReader.rawDigest(for: day)
        XCTAssertEqual(stored.count, appended.count + 1)
        XCTAssertEqual(
            digest,
            TaptionPlanV3Store.digest(
                events: stored,
                device: .iPhone,
                day: day
            )
        )
    }

    func testRawDigestCacheEvictsPastCapacity() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))
        )

        for offset in 0...TaptionPlanV3Store.rawDigestCacheCapacity {
            let date = try XCTUnwrap(
                calendar.date(byAdding: .day, value: offset, to: start)
            )
            let day = TaptionPlanDayKey(date: date, calendar: calendar)
            try await store.appendRawEvents([
                event(
                    day: day,
                    id: "event-\(offset)",
                    timestamp: TimeInterval(offset)
                ),
            ])
            _ = try await store.rawDigest(for: day)
        }

        let count = await store.rawDigestCacheCount
        XCTAssertEqual(count, TaptionPlanV3Store.rawDigestCacheCapacity)
    }

    func testMaterializedDayIsReplacedAsOneRowAndAllDaysIsIndexed() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .appleWatch)
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 30)
        let event = event(day: day, id: "watch-1", timestamp: 30, device: .appleWatch)
        try await store.appendRawEvents([event])
        let digest = try await store.rawDigest(for: day)
        let first = TaptionPlanMaterializedDay(
            device: .appleWatch,
            day: day,
            sourceRevision: 1,
            projectionVersion: 1,
            rawDigest: digest.sha256,
            rawEventCount: digest.eventCount,
            firstTimestamp: digest.firstTimestamp,
            lastTimestamp: digest.lastTimestamp,
            payload: Data([1])
        )
        try await store.replaceMaterializedDay(first)
        let second = TaptionPlanMaterializedDay(
            device: .appleWatch,
            day: day,
            sourceRevision: 2,
            projectionVersion: 1,
            rawDigest: digest.sha256,
            rawEventCount: digest.eventCount,
            firstTimestamp: digest.firstTimestamp,
            lastTimestamp: digest.lastTimestamp,
            payload: Data([2])
        )
        try await store.replaceMaterializedDay(second)

        let loadedValue = try await store.materializedDay(for: day)
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.sourceRevision, 2)
        XCTAssertEqual(loaded.payload, Data([2]))
        let days = try await store.allDays()
        XCTAssertEqual(days, [day])
    }

    func testMaterializedReplacementCASRejectsNewerWriter() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let staleWriter = try TaptionPlanV3Store(url: url, device: .iPhone)
        let currentWriter = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 22)
        let original = TaptionPlanMaterializedDay(
            device: .iPhone,
            day: day,
            sourceRevision: 1,
            projectionVersion: 1,
            rawDigest: "original",
            rawEventCount: 0,
            firstTimestamp: nil,
            lastTimestamp: nil,
            payload: Data([1])
        )
        let newer = TaptionPlanMaterializedDay(
            device: .iPhone,
            day: day,
            sourceRevision: 2,
            projectionVersion: 1,
            rawDigest: "newer",
            rawEventCount: 0,
            firstTimestamp: nil,
            lastTimestamp: nil,
            payload: Data([2])
        )
        let stale = TaptionPlanMaterializedDay(
            device: .iPhone,
            day: day,
            sourceRevision: 3,
            projectionVersion: 1,
            rawDigest: "stale",
            rawEventCount: 0,
            firstTimestamp: nil,
            lastTimestamp: nil,
            payload: Data([3])
        )

        try await staleWriter.replaceMaterializedDay(original)
        try await currentWriter.replaceMaterializedDay(newer)
        let replaced = try await staleWriter.replaceMaterializedDay(
            stale,
            onlyIfCurrent: original
        )

        XCTAssertFalse(replaced)
        let loaded = try await staleWriter.materializedDay(for: day)
        XCTAssertEqual(
            loaded?.payload,
            Data([2])
        )
    }

    func testStaleMaterializedRollbackPreservesNewerWriter() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let rollbackStore = try TaptionPlanV3Store(url: url, device: .iPhone)
        let writerStore = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 20)
        let stale = TaptionPlanMaterializedDay(
            device: .iPhone,
            day: day,
            sourceRevision: 2,
            projectionVersion: 1,
            rawDigest: "stale",
            rawEventCount: 1,
            firstTimestamp: nil,
            lastTimestamp: nil,
            payload: Data([2])
        )
        let newer = TaptionPlanMaterializedDay(
            device: .iPhone,
            day: day,
            sourceRevision: 3,
            projectionVersion: 1,
            rawDigest: "newer",
            rawEventCount: 2,
            firstTimestamp: nil,
            lastTimestamp: nil,
            payload: Data([3])
        )
        let previous = TaptionPlanMaterializedDay(
            device: .iPhone,
            day: day,
            sourceRevision: 1,
            projectionVersion: 1,
            rawDigest: "previous",
            rawEventCount: 1,
            firstTimestamp: nil,
            lastTimestamp: nil,
            payload: Data([1])
        )
        try await rollbackStore.replaceMaterializedDay(stale)
        try await writerStore.replaceMaterializedDay(newer)

        let restored = try await rollbackStore.restoreMaterializedDay(
            previous,
            for: day,
            onlyIfCurrent: stale
        )

        XCTAssertFalse(restored)
        let loaded = try await rollbackStore.materializedDay(for: day)
        XCTAssertEqual(loaded?.sourceRevision, newer.sourceRevision)
        XCTAssertEqual(loaded?.payload, newer.payload)
    }

    func testMaterializedRollbackComparesEveryPersistedColumn() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let rollbackStore = try TaptionPlanV3Store(url: url, device: .iPhone)
        let writerStore = try TaptionPlanV3Store(url: url, device: .iPhone)
        let baseTime = Date(timeIntervalSince1970: 10)

        for (index, changedColumn) in ["generatedAt", "firstTimestamp", "lastTimestamp"].enumerated() {
            let day = TaptionPlanDayKey(year: 2026, month: 9, day: 20 + index)
            let expected = TaptionPlanMaterializedDay(
                device: .iPhone,
                day: day,
                sourceRevision: 2,
                projectionVersion: 1,
                generatedAt: baseTime,
                rawDigest: "same",
                rawEventCount: 1,
                firstTimestamp: baseTime.addingTimeInterval(20),
                lastTimestamp: baseTime.addingTimeInterval(30),
                payload: Data([1])
            )
            let current = TaptionPlanMaterializedDay(
                device: .iPhone,
                day: day,
                sourceRevision: expected.sourceRevision,
                projectionVersion: expected.projectionVersion,
                generatedAt: changedColumn == "generatedAt"
                    ? baseTime.addingTimeInterval(1)
                    : expected.generatedAt,
                rawDigest: expected.rawDigest,
                rawEventCount: expected.rawEventCount,
                firstTimestamp: changedColumn == "firstTimestamp"
                    ? baseTime.addingTimeInterval(21)
                    : expected.firstTimestamp,
                lastTimestamp: changedColumn == "lastTimestamp"
                    ? baseTime.addingTimeInterval(31)
                    : expected.lastTimestamp,
                payload: expected.payload
            )
            try await rollbackStore.replaceMaterializedDay(expected)
            try await writerStore.replaceMaterializedDay(current)

            let restored = try await rollbackStore.restoreMaterializedDay(
                nil,
                for: day,
                onlyIfCurrent: expected
            )
            let loaded = try await rollbackStore.materializedDay(for: day)

            XCTAssertFalse(restored, "CAS must compare \(changedColumn)")
            XCTAssertEqual(loaded, current)
        }
    }

    func testMaterializedRollbackMatchesSQLiteDateRepresentation() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 21)
        let generatedAt = Date(
            timeIntervalSinceReferenceDate: 811_662_870.2363888
        )
        let expected = TaptionPlanMaterializedDay(
            device: .iPhone,
            day: day,
            sourceRevision: 2,
            projectionVersion: 1,
            generatedAt: generatedAt,
            rawDigest: "same",
            rawEventCount: 1,
            firstTimestamp: generatedAt.addingTimeInterval(60),
            lastTimestamp: generatedAt.addingTimeInterval(120),
            payload: Data([1])
        )
        try await store.replaceMaterializedDay(expected)

        let loaded = try await store.materializedDay(for: day)
        XCTAssertNotEqual(loaded?.generatedAt, expected.generatedAt)
        XCTAssertNotEqual(loaded?.firstTimestamp, expected.firstTimestamp)
        XCTAssertNotEqual(loaded?.lastTimestamp, expected.lastTimestamp)
        XCTAssertEqual(
            loaded?.generatedAt.timeIntervalSince1970,
            expected.generatedAt.timeIntervalSince1970
        )

        let restored = try await store.restoreMaterializedDay(
            nil,
            for: day,
            onlyIfCurrent: expected
        )

        XCTAssertTrue(restored)
        let afterRestore = try await store.materializedDay(for: day)
        XCTAssertNil(afterRestore)
    }

    func testThirtyDayColdAndWarmReadP95StaysInteractive() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let days = (1...30).map {
            TaptionPlanDayKey(year: 2026, month: 8, day: $0)
        }
        do {
            let store = try TaptionPlanV3Store(url: url, device: .iPhone)
            for (dayIndex, day) in days.enumerated() {
                let events = (0..<1_440).map { minute in
                    event(
                        day: day,
                        id: "gps-\(dayIndex)-\(minute)",
                        timestamp: TimeInterval(dayIndex * 86_400 + minute * 60),
                        provenance: ["iPhone.location", "CoreMotion"],
                        payload: Data(repeating: UInt8(minute % 255), count: 64)
                    )
                }
                try await store.appendRawEvents(events)
                let digest = try await store.rawDigest(for: day)
                try await store.replaceMaterializedDay(.init(
                    device: .iPhone,
                    day: day,
                    sourceRevision: 1,
                    projectionVersion: 1,
                    rawDigest: digest.sha256,
                    rawEventCount: digest.eventCount,
                    firstTimestamp: digest.firstTimestamp,
                    lastTimestamp: digest.lastTimestamp,
                    payload: Data(repeating: UInt8(dayIndex), count: 16_384)
                ))
            }
            try await store.checkpoint()
        }

        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        func readDurations() async throws -> [Double] {
            var milliseconds: [Double] = []
            for day in days {
                let started = DispatchTime.now().uptimeNanoseconds
                _ = try await store.rawDigest(for: day)
                _ = try await store.materializedDay(for: day)
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                milliseconds.append(Double(elapsed) / 1_000_000)
            }
            return milliseconds
        }
        func p95(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            let index = max(
                0,
                min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
            )
            return sorted[index]
        }

        let coldP95 = p95(try await readDurations())
        let warmP95 = p95(try await readDurations())
        print("DAY_STORE_30D_COLD_P95_MS=\(coldP95)")
        print("DAY_STORE_30D_WARM_P95_MS=\(warmP95)")
        XCTAssertLessThan(coldP95, 100)
        XCTAssertLessThan(warmP95, 50)
    }

    func testExistingV2StoreIsRejectedWithoutMutatingIt() throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        do {
            _ = try TaptionPlanDayStore(url: url)
        }
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(
            try TaptionPlanV3Store(url: url, device: .iPhone)
        ) { error in
            XCTAssertEqual(error as? TaptionPlanV3StoreError, .unsupportedSchema(0))
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testExistingUnsupportedDatabaseIsInspectedReadOnly() throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        try Data("not a sqlite database".utf8).write(to: url)
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(
            try TaptionPlanV3Store(url: url, device: .iPhone)
        )
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
    }

    private func event(
        day: TaptionPlanDayKey,
        id: String,
        timestamp: TimeInterval,
        device: TaptionPlanStoreDevice = .iPhone,
        provenance: [String] = ["test-source"],
        payload: Data = Data([7])
    ) -> TaptionPlanRawEvent {
        TaptionPlanRawEvent(
            device: device,
            day: day,
            timestamp: Date(timeIntervalSince1970: timestamp),
            sequence: UInt64(timestamp),
            id: id,
            domain: "gps",
            provenance: provenance,
            payload: payload
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-core-v3-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    private func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}
