import Foundation
import XCTest
@testable import TaptionPlanCore

final class StorageContractsTests: XCTestCase {
    func testCanonicalBinaryRoundTripAndChecksum() throws {
        let value = try TaptionPlanStorageEnvelopeV2(updatedAt: Date(timeIntervalSince1970: 12))
        let encoded = try TaptionPlanCanonicalStorage.encode(value)
        XCTAssertEqual(try TaptionPlanCanonicalStorage.decode(TaptionPlanStorageEnvelopeV2.self, from: encoded), value)
        var bytes = encoded.data
        bytes[bytes.startIndex] ^= 0xff
        let corrupted = TaptionPlanEncodedPayload(data: bytes, checksum: encoded.checksum, uncompressedSize: encoded.uncompressedSize, isCompressed: encoded.isCompressed)
        XCTAssertThrowsError(try TaptionPlanCanonicalStorage.decode(TaptionPlanStorageEnvelopeV2.self, from: corrupted))
    }

    func testCanonicalPayloadRejectsOversizedOrMismatchedDeclaredSize() throws {
        let oversized = TaptionPlanEncodedPayload(
            data: Data([1]),
            checksum: String(repeating: "0", count: 64),
            uncompressedSize: TaptionPlanCanonicalStorage.maximumUncompressedSize + 1,
            isCompressed: true
        )
        XCTAssertThrowsError(
            try TaptionPlanCanonicalStorage.decode(Data.self, from: oversized)
        ) { error in
            XCTAssertEqual(error as? TaptionPlanCanonicalStorageError, .invalidPayload)
        }

        let valid = try TaptionPlanCanonicalStorage.encode(["a", "b"], compress: false)
        let mismatched = TaptionPlanEncodedPayload(
            data: valid.data,
            checksum: valid.checksum,
            uncompressedSize: valid.uncompressedSize + 1,
            isCompressed: false
        )
        XCTAssertThrowsError(
            try TaptionPlanCanonicalStorage.decode([String].self, from: mismatched)
        ) { error in
            XCTAssertEqual(error as? TaptionPlanCanonicalStorageError, .invalidPayload)
        }
    }

    func testCanonicalCompressionSkipsSmallPayloadsAndCompressesLargePayloads() throws {
        let small = try TaptionPlanCanonicalStorage.encode(
            Data(repeating: 7, count: 512)
        )
        let largeValue = Data(repeating: 7, count: 64 * 1_024)
        let large = try TaptionPlanCanonicalStorage.encode(largeValue)

        XCTAssertFalse(small.isCompressed)
        XCTAssertTrue(large.isCompressed)
        XCTAssertLessThan(large.data.count, large.uncompressedSize)
        XCTAssertEqual(
            try TaptionPlanCanonicalStorage.decode(Data.self, from: large),
            largeValue
        )
    }

    func testRobustScalarFilterRejectsPhysicalAndIsolatedOutliersWithoutChangingInput() {
        let input: [Double?] = [1, 1.1, 0.9, 90, 1, 1.05, .nan, -1]
        let originalCount = input.count
        let filter = TaptionRobustScalarFilter(configuration: .init(
            physicalRange: 0...70,
            minimumAbsoluteDeviation: 0.05
        ))

        let decisions = filter.decisions(for: input)

        XCTAssertEqual(input.count, originalCount)
        XCTAssertEqual(decisions[3].reason, .abovePhysicalMaximum)
        XCTAssertEqual(decisions[6].reason, .nonFinite)
        XCTAssertEqual(decisions[7].reason, .belowPhysicalMinimum)
        XCTAssertEqual(decisions[0].acceptedValue, 1)
    }

    func testRobustScalarFilterChecksCancellationDuringLargeInputs() {
        let filter = TaptionRobustScalarFilter()
        var checks = 0

        XCTAssertThrowsError(
            try filter.decisions(
                for: Array(repeating: 1.0, count: 1_024),
                cancellationCheck: {
                    checks += 1
                    if checks == 3 { throw CancellationError() }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(checks, 3)
    }

    func testRobustScalarFilterRejectsSpikeButKeepsCoherentTransition() {
        let filter = TaptionRobustScalarFilter(configuration: .init(
            windowRadius: 3,
            minimumAbsoluteDeviation: 0.01
        ))
        let spike = filter.decisions(for: [0, 0, 0, 10, 0, 0, 0].map(Optional.some))
        XCTAssertEqual(spike[3].reason, .isolatedOutlier)

        let transition = filter.filteredValues([0, 0, 0, 10, 10, 10, 10].map(Optional.some))
        XCTAssertEqual(transition.compactMap { $0 }.count, 7)
    }

    func testBoundedCacheEvictsLRUAndRespondsToPressure() async throws {
        let cache = TaptionPlanDayLRUCache<String, Int>(capacity: 2)
        await cache.insert(1, for: "a")
        await cache.insert(2, for: "b")
        _ = try await cache.value(for: "a")
        await cache.insert(3, for: "c")
        let missing = try await cache.value(for: "b")
        let count = await cache.count
        XCTAssertNil(missing)
        XCTAssertEqual(count, 2)
        await cache.handleMemoryPressure()
        let cleared = await cache.count
        XCTAssertEqual(cleared, 0)
    }

    func testBoundedCacheSingleFlightsAndDropsLateLoaderResults() async throws {
        let gate = CacheLoaderGate()
        let cache = TaptionPlanDayLRUCache<String, Int>(capacity: 2) { _ in
            await gate.load()
        }
        let first = Task { try await cache.value(for: "same") }
        await gate.waitForCallCount(1)
        let second = Task { try await cache.value(for: "same") }
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        await gate.release(7)
        let firstValue = try await first.value
        let secondValue = try await second.value
        let cachedValue = try await cache.value(for: "same")
        XCTAssertEqual(firstValue, 7)
        XCTAssertEqual(secondValue, 7)
        XCTAssertEqual(cachedValue, 7)

        let lateGate = CacheLoaderGate()
        let lateCache = TaptionPlanDayLRUCache<String, Int>(capacity: 2) { _ in
            await lateGate.load()
        }
        let late = Task { try await lateCache.value(for: "same") }
        await lateGate.waitForCallCount(1)
        await lateCache.insert(9, for: "same")
        await lateGate.release(7)
        let lateValue = try await late.value
        let lateCachedValue = try await lateCache.value(for: "same")
        XCTAssertEqual(lateValue, 9)
        XCTAssertEqual(lateCachedValue, 9)
    }

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

private actor CacheLoaderGate {
    private(set) var calls = 0
    private var pending: [CheckedContinuation<Int, Never>] = []

    func load() async -> Int {
        calls += 1
        return await withCheckedContinuation { continuation in
            pending.append(continuation)
        }
    }

    func waitForCallCount(_ expected: Int) async {
        while calls < expected {
            await Task.yield()
        }
    }

    func release(_ value: Int) {
        let continuations = pending
        pending.removeAll()
        continuations.forEach { $0.resume(returning: value) }
    }
}
