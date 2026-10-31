import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

@MainActor
final class PredictedRoutePersistenceTests: XCTestCase {
    private func fixture() -> (TaptionDataSnapshot, MapPredictedRoute) {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let travel = TravelSegment(mode: .walking,
            span: TimeSpan(start: date, end: date.addingTimeInterval(120)),
            distanceMeters: 150, confidence: .low, evidence: ["GPS 공백"])
        var source = TaptionDataSnapshot.empty
        source.travel = [travel]
        let route = MapPredictedRoute(source: "gps-gap", travelID: travel.id, mode: .walking,
            span: travel.span, coordinates: [
                GeoPoint(latitude: 37, longitude: 127, altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1),
                GeoPoint(latitude: 37.001, longitude: 127.001, altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1)])
        return (source, route)
    }

    func testConfirmStoresFullGeometryAndSurvivesSQLiteReopen() async throws {
        let (source, route) = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("routes.sqlite")
        let repo = TaptionStoreRepository(store: try TaptionStoreV2(url: url))
        try await repo.save(source)
        let model = AppModel(repository: repo, cloudSyncService: nil)
        await model.bootstrap()
        let saved = await model.savePredictedRouteDecision(route, deleting: false)
        XCTAssertTrue(saved)
        let reopened = TaptionStoreRepository(store: try TaptionStoreV2(url: url))
        let loaded = try await reopened.load()
        let decision = try XCTUnwrap(loaded.settings.predictedRouteDecisions.first)
        XCTAssertEqual(decision.route, route)
        XCTAssertFalse(decision.isDeleted)
        XCTAssertTrue(try XCTUnwrap(loaded.travel.first).isConfirmed)
        XCTAssertTrue(try XCTUnwrap(loaded.travel.first).evidence.contains("GPS 공백"))
    }

    func testDeleteDecisionSurvivesRoundTripAndRegeneratedTravelID() async throws {
        let (source, route) = fixture()
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: source), cloudSyncService: nil)
        await model.bootstrap()
        let saved = await model.savePredictedRouteDecision(route, deleting: true)
        XCTAssertTrue(saved)
        let restored = try JSONDecoder().decode(TaptionDataSnapshot.self,
            from: JSONEncoder().encode(model.snapshot))
        let regenerated = MapPredictedRoute(source: route.source, travelID: UUID(), mode: route.mode,
            span: route.span, coordinates: route.coordinates)
        XCTAssertEqual(regenerated.id, route.id)
        XCTAssertEqual(restored.settings.predictedRouteDecisions.first?.id, regenerated.id)
        XCTAssertTrue(try XCTUnwrap(restored.settings.predictedRouteDecisions.first).isDeleted)
        let regeneratedDecision = try XCTUnwrap(restored.settings.predictedRouteDecisions.first)
        XCTAssertTrue(regeneratedDecision.matches(regenerated))
        XCTAssertEqual(restored.travel.map(\.id), source.travel.map(\.id))
        var otherPoints = route.coordinates
        otherPoints[1].longitude += 0.01
        let other = MapPredictedRoute(source: route.source, travelID: nil, mode: route.mode,
            span: route.span, coordinates: otherPoints)
        XCTAssertNotEqual(other.id, route.id)
        XCTAssertFalse(regeneratedDecision.matches(other))
    }

    func testRecomputedGeometryStaysConfirmedAndManualModeEditClearsIt() async throws {
        let (source, route) = fixture()
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: source), cloudSyncService: nil)
        await model.bootstrap()
        let saved = await model.savePredictedRouteDecision(route, deleting: false)
        XCTAssertTrue(saved)
        let decision = try XCTUnwrap(model.snapshot.settings.predictedRouteDecisions.first)
        var points = route.coordinates
        points[1].longitude += 0.0001
        let changed = MapPredictedRoute(source: route.source, travelID: route.travelID, mode: route.mode,
            span: route.span, coordinates: points)
        XCTAssertTrue(decision.matches(changed))
        let regenerated = MapPredictedRoute(source: route.source, travelID: UUID(), mode: route.mode,
            span: route.span, coordinates: points)
        XCTAssertTrue(decision.matches(regenerated))
        let following = MapPredictedRoute(source: route.source, travelID: UUID(), mode: route.mode,
            span: TimeSpan(start: route.span.end, end: route.span.end.addingTimeInterval(120)), coordinates: points)
        XCTAssertFalse(decision.matches(following))
        model.confirmTravel(try XCTUnwrap(route.travelID), mode: .running)
        XCTAssertTrue(model.snapshot.settings.predictedRouteDecisions.isEmpty)
    }

    func testSaveFailureDoesNotPublishConfirmationOrDeletion() async throws {
        let (source, route) = fixture()
        let repo = ControlledTransitBoardingRepository(snapshot: source)
        let model = AppModel(repository: repo, cloudSyncService: nil)
        await model.bootstrap()
        await repo.rejectConfirmations()
        let before = model.snapshot
        let confirmed = await model.savePredictedRouteDecision(route, deleting: false)
        let deleted = await model.savePredictedRouteDecision(route, deleting: true)
        XCTAssertFalse(confirmed)
        XCTAssertFalse(deleted)
        XCTAssertEqual(model.snapshot.settings.predictedRouteDecisions, before.settings.predictedRouteDecisions)
        XCTAssertEqual(model.snapshot.travel, before.travel)
    }

    func testDelayedSavePublishesAfterWriteAndRetainsConcurrentSetting() async throws {
        let (source, route) = fixture()
        let repo = ControlledTransitBoardingRepository(snapshot: source)
        let model = AppModel(repository: repo, cloudSyncService: nil)
        await model.bootstrap()
        await repo.holdConfirmations()
        let task = Task { await model.savePredictedRouteDecision(route, deleting: true) }
        await repo.waitForConfirmationWrite()
        XCTAssertTrue(model.snapshot.settings.predictedRouteDecisions.isEmpty)
        model.setMapDisplayStyle(.mapLibreCasual)
        await repo.releaseConfirmation()
        let saved = await task.value
        XCTAssertTrue(saved)
        XCTAssertEqual(model.snapshot.settings.mapDisplayStyle, .mapLibreCasual)
        XCTAssertTrue(try XCTUnwrap(model.snapshot.settings.predictedRouteDecisions.first).isDeleted)
    }
}
