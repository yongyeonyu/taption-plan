import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

@MainActor
final class TransitBoardingPersistenceTests: XCTestCase {
    private func fixture() throws -> (TaptionDataSnapshot, TransitBoardingCandidate, [SensorReading]) {
        let start = Date(timeIntervalSince1970: 1_790_208_000)
        let point = GeoPoint(latitude: 37.5248, longitude: 126.6744, altitude: 0,
            horizontalAccuracy: 10, verticalAccuracy: 10)
        let arrival = GeoPoint(latitude: 37.5667, longitude: 126.8273, altitude: 0,
            horizontalAccuracy: 10, verticalAccuracy: 10)
        let readings = [-180.0, -90, 0, 900].map {
            SensorReading(timestamp: start.addingTimeInterval($0),
                point: $0 == 900 ? arrival : point, locationFixQuality: .precise)
        }
        let segment = TravelSegment(mode: .train,
            span: TimeSpan(start: start, end: start.addingTimeInterval(900)),
            distanceMeters: 12_000, confidence: .low, evidence: ["자동 추정"])
        let location = UserTransitLocation(name: "검증용 출발역", kind: .subwayStation, point: point)
        let candidate = try XCTUnwrap(TransitBoardingCandidateEngine.candidates(readings: readings,
            registeredLocations: [location], travel: [segment]).first)
        XCTAssertEqual(candidate.subwayRoutes.count, 1)
        var source = TaptionDataSnapshot.empty
        source.travel = [segment]
        return (source, candidate, readings)
    }

    func testBoardingDecisionDoesNotConfirmFollowingJourney() throws {
        let (source, candidate, _) = try fixture()
        let segment = source.travel[0]
        let decision = TransitBoardingDecision(candidateKey: candidate.id,
            span: candidate.span, mode: candidate.mode, travelSegmentIDs: candidate.travelSegmentIDs,
            subwayRoutes: candidate.subwayRoutes)
        let following = TravelSegment(mode: .car,
            span: TimeSpan(start: segment.span.end.addingTimeInterval(60),
                end: segment.span.end.addingTimeInterval(600)),
            distanceMeters: 1_000, confidence: .low, evidence: ["다음 이동 자동 추정"])
        let result = TransitBoardingDecisionEngine.applying([decision], to: [segment, following])
        XCTAssertEqual(result[0].mode, .subway)
        XCTAssertEqual(result[1], following)
    }

    func testSavedRoutesPreferMatchingTravelIDWhenSpansOverlap() throws {
        let (source, candidate, _) = try fixture()
        let segment = source.travel[0]
        var other = segment
        other.id = UUID()
        var otherRoute = try XCTUnwrap(candidate.subwayRoutes.first)
        otherRoute.travelSegmentID = other.id
        otherRoute.route.stops.reverse()
        XCTAssertTrue(SubwayStationCatalog.isValid(otherRoute.route))
        XCTAssertNotEqual(otherRoute.route, candidate.subwayRoutes[0].route)
        let decision = TransitBoardingDecision(candidateKey: candidate.id,
            span: candidate.span, mode: .subway, travelSegmentIDs: [segment.id, other.id],
            subwayRoutes: candidate.subwayRoutes + [otherRoute])
        let result = TransitBoardingDecisionEngine.applying([decision], to: [segment, other])
        XCTAssertEqual(result[0].subwayRoute, candidate.subwayRoutes[0].route)
        XCTAssertEqual(result[1].subwayRoute, otherRoute.route)
        var sparseDecision = decision
        sparseDecision.subwayRoutes = [otherRoute]
        XCTAssertNil(TransitBoardingDecisionEngine.applying([sparseDecision], to: [segment])[0].subwayRoute,
            "a known travel ID without geometry must not borrow another travel's route")
        var regenerated = other
        regenerated.id = UUID()
        XCTAssertEqual(TransitBoardingDecisionEngine.applying([decision], to: [regenerated]), [regenerated],
            "ambiguous regenerated IDs must not select a different journey's route")
        let remaining = TransitBoardingDecisionEngine.removingConfirmations(for: [segment], from: [decision])
        XCTAssertEqual(remaining.first?.travelSegmentIDs, [other.id])
        XCTAssertEqual(remaining.first?.subwayRoutes, [otherRoute])
        let reapplied = TransitBoardingDecisionEngine.applying(remaining, to: [segment, other])
        XCTAssertEqual(reapplied[0], segment)
        XCTAssertEqual(reapplied[1].subwayRoute, otherRoute.route)
    }

    func testDeletionFailureKeepsCandidateVisibleAndUnstored() async throws {
        let (source, candidate, _) = try fixture()
        let repository = ControlledTransitBoardingRepository(snapshot: source)
        let model = AppModel(repository: repository, cloudSyncService: nil)
        await model.bootstrap()
        await repository.rejectConfirmations()
        let previous = model.snapshot
        let success = await model.deleteTransitBoardingCandidate(candidate)
        XCTAssertFalse(success)
        XCTAssertTrue(model.snapshot.settings.transitBoardingDecisions.isEmpty)
        XCTAssertEqual(model.snapshot.travel, previous.travel)
        let stored = try await repository.load()
        XCTAssertTrue(stored.settings.transitBoardingDecisions.isEmpty)
    }

    func testForgettingConfirmationRemovesReplayDecisionAndSavedGeometry() async throws {
        let (source, candidate, _) = try fixture()
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: source), cloudSyncService: nil)
        await model.bootstrap()
        let success = await model.confirmTransitBoarding(candidate)
        XCTAssertTrue(success)
        model.forgetTravelConfirmation(source.travel[0].id)
        XCTAssertTrue(model.snapshot.settings.transitBoardingDecisions.isEmpty)
        XCTAssertFalse(try XCTUnwrap(model.snapshot.travel.first).isConfirmed)
        XCTAssertNil(model.snapshot.travel.first?.subwayRoute)
        XCTAssertEqual(TransitBoardingDecisionEngine.applying(
            model.snapshot.settings.transitBoardingDecisions, to: model.snapshot.travel), model.snapshot.travel)
    }

    func testManualModeChangeClearsBoardingReplayAndSubwayGeometry() async throws {
        let (source, candidate, _) = try fixture()
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: source), cloudSyncService: nil)
        await model.bootstrap()
        let success = await model.confirmTransitBoarding(candidate)
        XCTAssertTrue(success)
        model.confirmTravel(source.travel[0].id, mode: .bus)
        XCTAssertTrue(model.snapshot.settings.transitBoardingDecisions.isEmpty)
        XCTAssertEqual(model.snapshot.travel.first?.mode, .bus)
        XCTAssertNil(model.snapshot.travel.first?.subwayRoute)
        XCTAssertFalse(try XCTUnwrap(model.snapshot.travel.first).evidence.contains(
            "사용자 확정 경로 · 역 좌표 기반 추정"))
        XCTAssertEqual(TransitBoardingDecisionEngine.applying(
            model.snapshot.settings.transitBoardingDecisions, to: model.snapshot.travel), model.snapshot.travel)
    }

    func testDeletionPublishesAfterWriteAndPreservesConcurrentSettingChange() async throws {
        let (source, candidate, readings) = try fixture()
        let repository = ControlledTransitBoardingRepository(snapshot: source)
        let model = AppModel(repository: repository, cloudSyncService: nil)
        await model.bootstrap()
        let previousTravel = model.snapshot.travel
        await repository.holdConfirmations()
        let task = Task { await model.deleteTransitBoardingCandidate(candidate) }
        await repository.waitForConfirmationWrite()
        XCTAssertTrue(model.snapshot.settings.transitBoardingDecisions.isEmpty)
        model.setMapDisplayStyle(.mapLibreCasual)
        await repository.releaseConfirmation()
        let success = await task.value
        XCTAssertTrue(success)
        let stored = try await repository.load()
        XCTAssertEqual(stored.settings.mapDisplayStyle, .mapLibreCasual)
        XCTAssertEqual(stored.travel, previousTravel)
        XCTAssertEqual(stored.settings.transitBoardingDecisions.count, 1)
        XCTAssertNil(stored.settings.transitBoardingDecisions[0].mode)
        let location = UserTransitLocation(name: candidate.name, kind: candidate.kind, point: candidate.point)
        XCTAssertTrue(TransitBoardingCandidateEngine.candidates(readings: readings,
            registeredLocations: [location], travel: stored.travel,
            decisions: stored.settings.transitBoardingDecisions).isEmpty)
    }

    func testConfirmationPersistsGeometryAndReloadsWithoutSensorReadings() async throws {
        let (source, candidate, _) = try fixture()
        let repository = InMemoryPlanRepository(snapshot: source)
        let model = AppModel(repository: repository, cloudSyncService: nil)
        await model.bootstrap()
        let success = await model.confirmTransitBoarding(candidate)
        XCTAssertTrue(success)
        let stored = try await repository.load()
        let segment = try XCTUnwrap(stored.travel.first)
        XCTAssertEqual(segment.mode, .subway)
        XCTAssertTrue(segment.isConfirmed)
        XCTAssertEqual(segment.subwayRoute, candidate.subwayRoutes.first?.route)
        XCTAssertTrue(segment.evidence.contains("자동 추정"))
        XCTAssertTrue(segment.evidence.contains("사용자 확정 경로 · 역 좌표 기반 추정"))
        let encoded = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(TaptionDataSnapshot.self, from: encoded)
        let reloaded = AppModel(repository: InMemoryPlanRepository(snapshot: decoded), cloudSyncService: nil)
        await reloaded.bootstrap()
        let restored = try XCTUnwrap(reloaded.snapshot.travel.first)
        XCTAssertEqual(restored.subwayRoute, segment.subwayRoute)
        let overlays = MapHomeSubwayRouteOverlayEngine.overlays(travel: [restored], readings: [],
            day: TimeSpan(start: segment.span.start.addingTimeInterval(-3600),
                end: segment.span.end.addingTimeInterval(3600)), through: segment.span.end)
        XCTAssertEqual(overlays.count, 1)
        XCTAssertFalse(try XCTUnwrap(overlays.first).estimated)
        XCTAssertEqual(overlays.first?.coordinates.count, segment.subwayRoute?.coordinates.count)
        var regenerated = source.travel[0]
        regenerated.id = UUID()
        let replayed = TransitBoardingDecisionEngine.applying(
            decoded.settings.transitBoardingDecisions, to: [regenerated])
        XCTAssertEqual(replayed.first?.subwayRoute, segment.subwayRoute)
        regenerated.span = TimeSpan(start: segment.span.start.addingTimeInterval(30),
            end: segment.span.end.addingTimeInterval(-30))
        let shifted = TransitBoardingDecisionEngine.applying(
            decoded.settings.transitBoardingDecisions, to: [regenerated])
        XCTAssertEqual(shifted.first?.subwayRoute, segment.subwayRoute)
        XCTAssertEqual(shifted.first?.span, segment.span)
        regenerated.span = TimeSpan(start: segment.span.end.addingTimeInterval(60),
            end: segment.span.end.addingTimeInterval(600))
        XCTAssertNil(TransitBoardingDecisionEngine.applying(
            decoded.settings.transitBoardingDecisions, to: [regenerated]).first?.subwayRoute)
    }

    func testConfirmationFailureDoesNotPublishOrStoreConfirmedRoute() async throws {
        let (source, candidate, _) = try fixture()
        let repository = ControlledTransitBoardingRepository(snapshot: source)
        let model = AppModel(repository: repository, cloudSyncService: nil)
        await model.bootstrap()
        await repository.rejectConfirmations()
        let previous = model.snapshot
        let success = await model.confirmTransitBoarding(candidate)
        XCTAssertFalse(success)
        XCTAssertEqual(model.snapshot.travel, previous.travel)
        XCTAssertEqual(model.snapshot.settings.transitBoardingDecisions, [])
        let stored = try await repository.load()
        XCTAssertEqual(stored.settings.transitBoardingDecisions, [])
        XCTAssertNil(stored.travel.first?.subwayRoute)
    }

    func testConfirmedGeometrySurvivesOpeningAnotherSQLiteConnection() async throws {
        let (source, candidate, _) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MAP1013A01-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("plan.sqlite")
        let repository = TaptionStoreRepository(store: try TaptionStoreV2(url: url))
        try await repository.save(source)
        let model = AppModel(repository: repository, cloudSyncService: nil)
        await model.bootstrap()
        let success = await model.confirmTransitBoarding(candidate)
        XCTAssertTrue(success)
        let stored = try await TaptionStoreRepository(store: TaptionStoreV2(url: url)).load()
        XCTAssertEqual(stored.travel.first?.subwayRoute, candidate.subwayRoutes.first?.route)
        XCTAssertEqual(stored.settings.transitBoardingDecisions.first?.subwayRoutes, candidate.subwayRoutes)
    }

    func testConfirmationPublishesOnlyAfterWriteAndKeepsOriginalDay() async throws {
        let (source, candidate, _) = try fixture()
        let repository = ControlledTransitBoardingRepository(snapshot: source)
        let model = AppModel(repository: repository, cloudSyncService: nil)
        await model.bootstrap()
        await repository.holdConfirmations()
        let task = Task { await model.confirmTransitBoarding(candidate) }
        await repository.waitForConfirmationWrite()
        XCTAssertFalse(try XCTUnwrap(model.snapshot.travel.first).isConfirmed)
        XCTAssertTrue(model.snapshot.settings.transitBoardingDecisions.isEmpty)
        model.selectedDate = candidate.span.start.addingTimeInterval(86_400)
        await repository.releaseConfirmation()
        let success = await task.value
        XCTAssertTrue(success)
        XCTAssertEqual(model.snapshot.travel.first?.span, source.travel.first?.span)
        XCTAssertEqual(model.snapshot.travel.first?.subwayRoute, candidate.subwayRoutes.first?.route)
    }

    func testCancelledOrStaleCandidateDoesNotConfirmAnotherTravel() async throws {
        let (source, candidate, _) = try fixture()
        let repository = InMemoryPlanRepository(snapshot: source)
        let model = AppModel(repository: repository, cloudSyncService: nil)
        await model.bootstrap()
        let task = Task { await model.confirmTransitBoarding(candidate) }
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result)
        let stale = TransitBoardingCandidate(id: "stale", placeID: candidate.placeID,
            locationID: candidate.locationID, name: candidate.name, kind: candidate.kind,
            point: candidate.point, span: candidate.span, dwellDuration: candidate.dwellDuration,
            source: candidate.source, travelSegmentIDs: [UUID()], subwayRoutes: candidate.subwayRoutes)
        let staleResult = await model.confirmTransitBoarding(stale)
        XCTAssertFalse(staleResult)
        XCTAssertTrue(model.snapshot.settings.transitBoardingDecisions.isEmpty)
        XCTAssertFalse(try XCTUnwrap(model.snapshot.travel.first).isConfirmed)
    }

    func testConcurrentSettingChangeSurvivesConfirmationWrite() async throws {
        let (source, candidate, _) = try fixture()
        let repository = ControlledTransitBoardingRepository(snapshot: source)
        let model = AppModel(repository: repository, cloudSyncService: nil)
        await model.bootstrap()
        await repository.holdConfirmations()
        let task = Task { await model.confirmTransitBoarding(candidate) }
        await repository.waitForConfirmationWrite()
        model.setMapDisplayStyle(.mapLibreCasual)
        await repository.releaseConfirmation()
        let success = await task.value
        XCTAssertTrue(success)
        let stored = try await repository.load()
        XCTAssertEqual(stored.settings.mapDisplayStyle, .mapLibreCasual)
        XCTAssertEqual(stored.travel.first?.subwayRoute, candidate.subwayRoutes.first?.route)
        XCTAssertEqual(model.settings.mapDisplayStyle, .mapLibreCasual)
    }
}
