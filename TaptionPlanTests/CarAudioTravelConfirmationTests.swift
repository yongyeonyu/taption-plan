import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

// MARK: - CAR1029A01 차량 오디오 연결로 자동차 확정

final class CarAudioTravelConfirmationTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var span: TimeSpan { TimeSpan(start: base, end: base.addingTimeInterval(30 * 60)) }

    /// 지하철처럼 보이는 표본(역 근처·철도 경로)에 분 단위로 차량 오디오 이름을 붙인다.
    private func reading(minute: Double, carAudio: String?, subwayLike: Bool = true) -> SensorReading {
        SensorReading(
            timestamp: base.addingTimeInterval(minute * 60),
            point: GeoPoint(
                latitude: 37.5 + minute * 0.001,
                longitude: 126.9 + minute * 0.001,
                altitude: 20,
                horizontalAccuracy: 10,
                verticalAccuracy: 8
            ),
            speedMetersPerSecond: 12,
            motion: .automotive,
            motionConfidence: .high,
            nearbyStation: subwayLike,
            matchesRailRoute: subwayLike,
            sourceDevice: .iPhone,
            carAudioRouteName: carAudio
        )
    }

    private func readings(_ name: (Double) -> String?, minutes: StrideThrough<Double>) -> [SensorReading] {
        minutes.map { reading(minute: $0, carAudio: name($0)) }
    }

    func testRegisteredCarConnectedThroughSpanConfirmsCar() {
        let samples = readings({ _ in "KIA K5" }, minutes: stride(from: 0, through: 30, by: 2))

        let inference = TravelModeClassifier().classify(
            readings: samples,
            inside: span,
            registeredCarAudioNames: ["KIA K5"]
        )

        XCTAssertEqual(inference.mode, .car)
        XCTAssertEqual(inference.confidence, .high)
        XCTAssertEqual(inference.evidence, ["사용자 확인 차량 블루투스 · KIA K5"])
        XCTAssertTrue(CarAudioTravelConfirmation.confirms(inference.evidence))
    }

    func testUnregisteredConnectAndDisconnectMatchingSpanConfirmsCar() {
        let samples = readings({ minute in (2...28).contains(minute) ? "KIA K5" : nil },
                               minutes: stride(from: -10, through: 40, by: 2))
        let inside = samples.filter { span.contains($0.timestamp) }

        let inference = TravelModeClassifier().classify(
            readings: inside,
            inside: span,
            altitudeContext: samples
        )

        XCTAssertEqual(inference.mode, .car)
        XCTAssertEqual(inference.evidence, ["차량 오디오 연결·해제 일치 · KIA K5"])
        XCTAssertTrue(CarAudioTravelConfirmation.confirms(inference.evidence))
        XCTAssertEqual(CarAudioTravelConfirmation.matchedName(in: inference.evidence[0]), "KIA K5")
    }

    /// 걷는 동안 연결돼 있던 이어폰은 연결·해제가 구간과 맞아도 차로 확정하지 않는다(SUB1111A01).
    func testHeadsetWornWhileWalkingDoesNotConfirmCar() {
        var walk = stride(from: -10.0, through: 0, by: 0.25).map { reading(minute: $0, carAudio: "넥밴드", subwayLike: false) }
        for index in walk.indices { walk[index].motion = .walking }
        let ride = readings({ minute in (0...28).contains(minute) ? "넥밴드" : nil }, minutes: stride(from: 2, through: 40, by: 2))
        let samples = walk + ride
        let inside = samples.filter { span.contains($0.timestamp) }

        XCTAssertEqual(CarAudioTravelConfirmation.wornAudioNames(in: samples), ["넥밴드"])
        let inference = TravelModeClassifier().classify(readings: inside, inside: span, altitudeContext: samples)
        XCTAssertFalse(CarAudioTravelConfirmation.confirms(inference.evidence), "\(inference.evidence)")
        // 등록한 차 이름이면 걸으며 연결돼 있었어도 차다.
        let registered = TravelModeClassifier().classify(readings: inside, inside: span, altitudeContext: samples,
                                                         registeredCarAudioNames: ["넥밴드"])
        XCTAssertEqual(registered.mode, .car)
    }

    /// 차에 탄 뒤에만 연결되는 차량 오디오는 걷기 표본과 겹치지 않아 그대로 차다.
    func testCarAudioConnectedOnlyInsideTheCarIsNotWorn() {
        var walk = stride(from: -10.0, through: 0, by: 0.25).map { reading(minute: $0, carAudio: nil, subwayLike: false) }
        for index in walk.indices { walk[index].motion = .walking }
        let ride = readings({ minute in (2...28).contains(minute) ? "KIA K5" : nil }, minutes: stride(from: 2, through: 40, by: 2))
        XCTAssertTrue(CarAudioTravelConfirmation.wornAudioNames(in: walk + ride).isEmpty)
    }

    /// 잠근 구간이 이어폰으로 확정된 자동차였어도, 새 판정이 그 근거를 못 찾으면 자동차·확정을 물려받지 않는다.
    func testLockedMatchedCarAudioIsNotInheritedWhenFreshJudgementDropsIt() {
        var previous = TravelSegment(mode: .car, span: span, distanceMeters: 300, confidence: .high,
                                     evidence: ["차량 오디오 연결·해제 일치 · 넥밴드"], isConfirmed: true)
        previous.isClassificationLocked = true
        let fresh = TravelSegment(mode: .walking, span: span, distanceMeters: 300, confidence: .high,
                                  evidence: ["iPhone Core Motion 걷기"], isConfirmed: false)
        let merged = ActivityClassificationLockEngine.mergingLockedTravel(existing: [previous], fresh: [fresh], inside: span)
        XCTAssertEqual(merged.map(\.mode), [.walking])
        XCTAssertEqual(merged.map(\.isConfirmed), [false])
    }

    func testUnregisteredDeviceConnectedAllDayDoesNotConfirm() {
        let samples = readings({ _ in "홈 스피커" }, minutes: stride(from: -120, through: 150, by: 2))
        let inside = samples.filter { span.contains($0.timestamp) }

        let inference = TravelModeClassifier().classify(
            readings: inside,
            inside: span,
            altitudeContext: samples
        )
        let unchanged = TravelModeClassifier().classify(
            readings: inside.map { var value = $0; value.carAudioRouteName = nil; return value },
            inside: span,
            altitudeContext: samples.map { var value = $0; value.carAudioRouteName = nil; return value }
        )

        XCTAssertNil(CarAudioTravelConfirmation.evaluate(
            readings: inside, context: samples, span: span, registered: []
        ))
        XCTAssertEqual(inference.mode, unchanged.mode)
        XCTAssertFalse(CarAudioTravelConfirmation.confirms(inference.evidence))
    }

    func testConnectionWithoutAnyRouteReadingsChangesNothing() {
        let samples = readings({ _ in nil }, minutes: stride(from: 0, through: 30, by: 2))

        XCTAssertNil(CarAudioTravelConfirmation.evaluate(
            readings: samples, span: span, registered: ["KIA K5"]
        ))
    }

    func testRecentNamesCollectMatchedDevicesMostRecentFirst() {
        let older = TravelSegment(
            mode: .car, span: span, distanceMeters: 1, confidence: .high,
            evidence: ["차량 오디오 연결·해제 일치 · KIA K5"], isConfirmed: true
        )
        let newer = TravelSegment(
            mode: .car,
            span: TimeSpan(start: base.addingTimeInterval(3600), end: base.addingTimeInterval(5400)),
            distanceMeters: 1, confidence: .high,
            evidence: ["차량 오디오 연결·해제 일치 · 렌터카"], isConfirmed: true
        )
        let registered = TravelSegment(
            mode: .car, span: span, distanceMeters: 1, confidence: .high,
            evidence: ["사용자 확인 차량 블루투스 · 내 차"], isConfirmed: true
        )

        let names = CarAudioTravelConfirmation.recentNames(
            from: [older, newer, registered], merging: ["KIA K5", "예전 기기"]
        )

        XCTAssertEqual(names, ["렌터카", "KIA K5", "예전 기기"])
    }

    func testSensorReadingCarAudioRouteNameRoundTripsAndDecodesNilFromOldJSON() throws {
        let reading = SensorReading(timestamp: base, carAudioRouteName: "KIA K5")
        let data = try JSONEncoder().encode(reading)
        let decoded = try JSONDecoder().decode(SensorReading.self, from: data)
        XCTAssertEqual(decoded.carAudioRouteName, "KIA K5")

        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "carAudioRouteName")
        let legacy = try JSONDecoder().decode(
            SensorReading.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(legacy.carAudioRouteName)
        XCTAssertEqual(legacy.timestamp, reading.timestamp)
    }

    func testSettingsCarAudioNamesDefaultEmptyAndNormalize() throws {
        let settings = AppFeatureSettings(
            startScale: .day, rememberLastScale: false, catStyle: .calico, reduceMotion: false,
            showsPhotos: false, showsPhotosInWidgets: false, selectedCalendarIDs: [],
            healthEnabled: false, locationEnabled: false, backgroundPreciseLocationEnabled: false,
            sensorCollectionProfile: .balanced, weatherEnabled: false, notificationsEnabled: false,
            permissions: [:], registeredCarAudioNames: [" KIA K5 ", "KIA K5", ""]
        )
        XCTAssertEqual(settings.registeredCarAudioNames, ["KIA K5"])
        XCTAssertEqual(settings.recentCarAudioNames, [])

        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        )
        object.removeValue(forKey: "registeredCarAudioNames")
        object.removeValue(forKey: "recentCarAudioNames")
        let legacy = try JSONDecoder().decode(
            AppFeatureSettings.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(legacy.registeredCarAudioNames, [])
        XCTAssertEqual(legacy.recentCarAudioNames, [])
    }
}
