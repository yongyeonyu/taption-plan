import Foundation
import XCTest
@testable import TaptionAssistantKit

/// Apple 모델 3단계 길(PCC1118A01). 가용성은 가짜 값으로 넣는다.
final class AppleModelRouterTests: XCTestCase {
    private func conditions(
        _ task: AppleModelTask = .memoPolish,
        cloud: AppleCloudModelState = .available(.belowLimit),
        device: AppleDeviceModelState = .available,
        online: Bool = true,
        length: Int = 200,
        allowsCloud: Bool = true
    ) -> AppleModelConditions {
        AppleModelConditions(task: task, cloud: cloud, device: device, isOnline: online, inputLength: length, allowsCloud: allowsCloud)
    }

    func testCloudAvailableUsesPrivateCloud() {
        XCTAssertEqual(AppleModelRouter.decide(conditions()), AppleModelDecision(.privateCloud))
        XCTAssertEqual(AppleModelRouter.decide(conditions(.daySummary, device: .unsupported, length: 5_000)), AppleModelDecision(.privateCloud))
    }

    func testApproachingLimitStaysOnCloudWithNotice() {
        XCTAssertEqual(AppleModelRouter.decide(conditions(cloud: .available(.approachingLimit))),
                       AppleModelDecision(.privateCloud, notice: .cloudQuotaApproaching))
    }

    func testQuotaReachedFallsBackToDeviceWithNotice() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(AppleModelRouter.decide(conditions(cloud: .available(.limitReached(resetDate: reset)))),
                       AppleModelDecision(.onDevice, notice: .cloudQuotaReached(resetDate: reset)))
    }

    func testQuotaReachedAndTooLongGoesToQueueWithQuotaNotice() {
        XCTAssertEqual(AppleModelRouter.decide(conditions(cloud: .available(.limitReached(resetDate: nil)), length: 2_000)),
                       AppleModelDecision(.relayQueue, notice: .cloudQuotaReached(resetDate: nil)))
    }

    func testOfflineUsesDevice() {
        XCTAssertEqual(AppleModelRouter.decide(conditions(online: false)), AppleModelDecision(.onDevice))
    }

    func testDeviceInputOverLimitGoesToQueue() {
        let limit = AppleModelTask.memoPolish.onDeviceInputLimit
        XCTAssertEqual(AppleModelRouter.decide(conditions(online: false, length: limit)).route, .onDevice)
        XCTAssertEqual(AppleModelRouter.decide(conditions(online: false, length: limit + 1)),
                       AppleModelDecision(.relayQueue, notice: .inputTooLongForDevice))
    }

    func testDaySummaryNeverRunsOnDevice() {
        XCTAssertEqual(AppleModelRouter.decide(conditions(.daySummary, online: false, length: 100)), AppleModelDecision(.relayQueue))
    }

    func testUnsupportedOrOlderOSGoesToQueue() {
        // iOS 26 미만: 두 모델 다 없다. iOS 26: PCC만 없고 기기 모델이 없으면 큐.
        XCTAssertEqual(AppleModelRouter.decide(conditions(cloud: .unsupported, device: .unsupported)), AppleModelDecision(.relayQueue))
        XCTAssertEqual(AppleModelRouter.decide(conditions(cloud: .unsupported, device: .unavailable)), AppleModelDecision(.relayQueue))
        XCTAssertEqual(AppleModelRouter.decide(conditions(cloud: .unsupported)), AppleModelDecision(.onDevice))
    }

    /// entitlement가 없으면 iOS가 unavailable로 알리거나 부를 때 거절한다. 어느 쪽이든 기기 모델로 간다.
    func testMissingEntitlementFallsBackToDevice() {
        XCTAssertEqual(AppleModelRouter.decide(conditions(cloud: .unavailable)), AppleModelDecision(.onDevice))
        XCTAssertEqual(AppleModelRouter.decide(after: .service, conditions()), AppleModelDecision(.onDevice))
    }

    func testCloudFailureRedecidesWithoutCloud() {
        XCTAssertEqual(AppleModelRouter.decide(after: .quotaReached(resetDate: nil), conditions()),
                       AppleModelDecision(.onDevice, notice: .cloudQuotaReached(resetDate: nil)))
        XCTAssertEqual(AppleModelRouter.decide(after: .network, conditions(length: 3_000)),
                       AppleModelDecision(.relayQueue, notice: .inputTooLongForDevice))
    }

    func testCloudNotAllowedStaysOnDevice() {
        XCTAssertEqual(AppleModelRouter.decide(conditions(allowsCloud: false)), AppleModelDecision(.onDevice))
        XCTAssertEqual(AppleModelRouter.decide(conditions(cloud: .available(.limitReached(resetDate: nil)), allowsCloud: false)),
                       AppleModelDecision(.onDevice))
    }

    func testEmptyInputGoesNowhereButQueue() {
        XCTAssertEqual(AppleModelRouter.decide(conditions(length: 0)).route, .relayQueue)
    }

    func testCoordinateDetection() {
        XCTAssertTrue(AppleModelRouter.containsCoordinates("여기 12.3456, 123.4567 에서 만남"))
        XCTAssertTrue(AppleModelRouter.containsCoordinates("-12.34560/123.45670"))
        XCTAssertFalse(AppleModelRouter.containsCoordinates("점심 12,000원, 3.5km 걸음"))
        XCTAssertFalse(AppleModelRouter.containsCoordinates("1.5배 2.25"))
        // 리뷰(CRV1118A01): 소수 3자리·도분·지도 링크도 좌표로 본다.
        XCTAssertTrue(AppleModelRouter.containsCoordinates("12.345,123.456"))
        XCTAssertTrue(AppleModelRouter.containsCoordinates("12°34′56″N 123°45′"))
        XCTAssertTrue(AppleModelRouter.containsCoordinates("https://maps.example/?q=12.3,123.4"))
        XCTAssertTrue(AppleModelRouter.containsCoordinates("https://maps.example/@12.34,123.45,15z"))
        XCTAssertTrue(AppleModelRouter.containsCoordinates("map?ll=12.3%2C123.4"))
        XCTAssertFalse(AppleModelRouter.containsCoordinates("기온 12°, 1.25배"))
    }

    /// 좌표가 든 글은 기기 모델이 못 하면 중계 큐(기기 밖)로도 보내지 않는다.
    func testCoordinatesNeverGoToQueue() {
        XCTAssertEqual(AppleModelRouter.decide(conditions(device: .unavailable, allowsCloud: false)),
                       AppleModelDecision(.notAvailable, notice: .keepsCoordinates))
        XCTAssertEqual(AppleModelRouter.decide(conditions(length: 3_000, allowsCloud: false)),
                       AppleModelDecision(.notAvailable, notice: .keepsCoordinates))
        XCTAssertEqual(AppleModelRouter.decide(conditions(cloud: .unavailable, device: .unavailable, allowsCloud: true)).route, .relayQueue)
    }

    func testConditionsAfterFailureMatchesDecideAfter() {
        let base = conditions()
        XCTAssertEqual(AppleModelRouter.decide(AppleModelRouter.conditions(after: .network, base)),
                       AppleModelRouter.decide(after: .network, base))
        XCTAssertFalse(AppleModelRouter.conditions(after: .network, base).isOnline)
    }
}
