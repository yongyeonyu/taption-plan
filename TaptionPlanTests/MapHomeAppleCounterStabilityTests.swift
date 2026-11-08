import MapKit
import SwiftUI
import UIKit
import XCTest
@testable import TaptionPlan

@MainActor
final class MapHomeAppleCounterStabilityTests: XCTestCase {
    private let offset = CGPoint(x: 0, y: -18)
    private let size = CGSize(width: 36, height: 36)
    private let target = CGPoint(x: 195, y: 520)

    func testNoiseAroundTargetKeepsExactlyOneCenter() {
        let noise: [CGPoint] = [.zero, .init(x: 0.33, y: -0.41), .init(x: -2.7, y: 1.9), .init(x: 4, y: -4)]
        let centers = Set(noise.map { delta -> String in
            let point = CGPoint(x: target.x + delta.x, y: target.y + delta.y)
            let center = MapHomeAppleMarkerPlacement.center(actual: point, lockTarget: target, offset: offset, size: size, scale: 3)
            return "\(center.x),\(center.y)"
        })
        XCTAssertEqual(centers.count, 1)
    }

    func testFarFromTargetFollowsActualPoint() {
        let actual = CGPoint(x: target.x + 40, y: target.y)
        let center = MapHomeAppleMarkerPlacement.center(actual: actual, lockTarget: target, offset: offset, size: size, scale: 3)
        XCTAssertEqual(center.x, actual.x, accuracy: 1.0 / 3)
        XCTAssertEqual(center.y, actual.y - 18, accuracy: 1.0 / 3)
    }

    func testOriginLandsOnDevicePixelForOddSizes() {
        let center = MapHomeAppleMarkerPlacement.center(
            actual: CGPoint(x: 100.37, y: 200.81), lockTarget: nil, offset: .zero, size: CGSize(width: 37, height: 35), scale: 3
        )
        let originX = (center.x - 18.5) * 3, originY = (center.y - 17.5) * 3
        XCTAssertEqual(originX, originX.rounded(), accuracy: 0.0001)
        XCTAssertEqual(originY, originY.rounded(), accuracy: 0.0001)
    }

    /// 실제 지도에서 재생 카메라를 돌려 되읽은 점이 잠금 허용 오차 안에 드는지 잰다.
    func testPlaybackCameraKeepsWalkerWithinLockTolerance() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let mapView = MKMapView(frame: window.bounds)
        window.addSubview(mapView)
        window.isHidden = false
        defer { window.isHidden = true }
        mapView.camera = MKMapCamera(
            lookingAtCenter: CLLocationCoordinate2D(latitude: 37.5, longitude: 126.9), fromDistance: 4_000, pitch: 0, heading: 0
        )
        mapView.layoutIfNeeded()
        var settled: [CGFloat] = []
        for frame in 0..<240 {
            let step = Double(frame)
            let coordinate = CLLocationCoordinate2D(latitude: 37.5 + step * 0.00002, longitude: 126.9 + step * 0.00003)
            let distance = 4_000 + sin(step / 40) * 800
            MapHomeAppleCameraCommand.center(coordinate, at: target, distance: distance, on: mapView)
            let point = mapView.convert(coordinate, toPointTo: mapView)
            if frame > 5 { settled.append(hypot(point.x - target.x, point.y - target.y)) }
        }
        let sorted = settled.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)], maximum = try XCTUnwrap(sorted.last)
        print("CTR1103A02 convert-target mean=\(sorted.reduce(0, +) / CGFloat(sorted.count)) p95=\(p95) max=\(maximum)")
        XCTAssertLessThanOrEqual(p95, MapHomeAppleMarkerPlacement.lockTolerance)
    }

    func testKernsWidenEveryDigitToTheWidest() {
        let kerns = MapHomeCounterDigits.kerns(digitWidths: ["1": 4.5, "4": 7, "7": 7])
        XCTAssertEqual(kerns, ["1": 2.5])
        XCTAssertTrue(MapHomeCounterDigits.kerns(digitWidths: ["0": 6, "1": 6]).isEmpty)
    }

    /// SwiftUI가 실제로 재는 폭으로 확인한다. 자간이 없으면 값마다 폭이 달라야 시험이 의미 있다.
    func testJuaValueWidthDoesNotDependOnDigits() {
        let name = "Jua-Regular"
        let kerns = MapHomeCounterDigits.kerns(fontName: name, size: 11)
        XCTAssertFalse(kerns.isEmpty, "주아는 고정폭 숫자 기능이 없다")
        func width(_ text: String, kerned: Bool) -> CGFloat {
            let value = MapHomeCounterDigits.attributed(text, kerns: kerned ? kerns : [:])
            let host = UIHostingController(rootView: Text(value).font(.custom(name, fixedSize: 11)).monospacedDigit().fixedSize())
            return host.sizeThatFits(in: CGSize(width: 500, height: 100)).width
        }
        XCTAssertGreaterThan(abs(width("1,111", kerned: false) - width("4,444", kerned: false)), 5)
        XCTAssertEqual(width("1,111", kerned: true), width("4,444", kerned: true), accuracy: 0.5)
        XCTAssertEqual(width("1.1km", kerned: true), width("8.0km", kerned: true), accuracy: 0.5)
    }

    func testFontsWithTabularFeatureGetNoKerning() {
        XCTAssertTrue(MapHomeCounterDigits.kerns(fontName: "Pretendard-Bold", size: 11).isEmpty)
        XCTAssertTrue(MapHomeCounterDigits.kerns(fontName: nil, size: 11).isEmpty)
    }

    func testKnownSizeSkipsMeasuringAndStillSizesHost() {
        let follower = MapHomeLivePointFollowerView(rootView: Color.clear.frame(width: 10, height: 10))
        follower.knownContentSize = CGSize(width: 240, height: 320)
        follower.configure(channel: nil, fallback: .zero, offset: .zero, onFrame: nil)
        XCTAssertEqual(follower.host.view.bounds.size, CGSize(width: 240, height: 320))
    }
}
