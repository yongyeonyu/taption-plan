import SwiftUI
import UIKit
import XCTest
@testable import TaptionPlan

/// OPT1102A01: 시작·배터리·제스처 경량화가 동작을 바꾸지 않는지 본다.
@MainActor
final class RuntimeEfficiencyTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var file: URL!

    override func setUp() async throws {
        suiteName = "RuntimeEfficiencyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
            .appendingPathComponent("app-settings.plist")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func testSettingsRestoreWritesOnlyChangedKeys() throws {
        defaults.set(3, forKey: "same")
        defaults.set("old", forKey: "changed")
        let plist: [String: Any] = ["same": 3, "changed": "new", "added": [1, 2], "date": Date(timeIntervalSince1970: 9)]
        try write(plist, format: .binary)

        XCTAssertEqual(AppSettingsFile.restore(from: file, to: defaults), 3)
        XCTAssertEqual(defaults.integer(forKey: "same"), 3)
        XCTAssertEqual(defaults.string(forKey: "changed"), "new")
        XCTAssertEqual(defaults.array(forKey: "added") as? [Int], [1, 2])
        XCTAssertEqual(defaults.object(forKey: "date") as? Date, Date(timeIntervalSince1970: 9))
        XCTAssertEqual(AppSettingsFile.restore(from: file, to: defaults), 0)
    }

    /// 이전 빌드가 남긴 XML 파일도 읽혀야 업데이트 뒤 설정이 유지된다.
    func testSettingsRestoreReadsPreviousXMLFile() throws {
        try write(["legacy": true], format: .xml)
        XCTAssertEqual(AppSettingsFile.restore(from: file, to: defaults), 1)
        XCTAssertTrue(defaults.bool(forKey: "legacy"))
    }

    func testSettingsSaveSkipsUnchangedContentAndRoundTrips() throws {
        defaults.set("value", forKey: "key")
        XCTAssertTrue(AppSettingsFile.save(to: file, from: defaults))
        let writtenAt = try XCTUnwrap(modificationDate())
        try FileManager.default.setAttributes([.modificationDate: writtenAt.addingTimeInterval(-60)], ofItemAtPath: file.path)
        let stamped = modificationDate()

        XCTAssertFalse(AppSettingsFile.save(to: file, from: defaults))
        XCTAssertEqual(modificationDate(), stamped)

        defaults.set("next", forKey: "key")
        XCTAssertTrue(AppSettingsFile.save(to: file, from: defaults))

        let restored = try XCTUnwrap(UserDefaults(suiteName: suiteName + ".restored"))
        defer { restored.removePersistentDomain(forName: suiteName + ".restored") }
        XCTAssertGreaterThan(AppSettingsFile.restore(from: file, to: restored), 0)
        XCTAssertEqual(restored.string(forKey: "key"), "next")
    }

    func testSettingsSaveRewritesWhenFileWasRemoved() throws {
        defaults.set(1, forKey: "key")
        XCTAssertTrue(AppSettingsFile.save(to: file, from: defaults))
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(AppSettingsFile.save(to: file, from: defaults))
    }

    func testObservedGesturesAttachOnceAndDetachRemoved() {
        let target = GestureTarget()
        let view = UIView(), child = UIView()
        view.addSubview(child)
        let kept = UIPanGestureRecognizer(), removed = UIPanGestureRecognizer()
        view.addGestureRecognizer(kept)
        child.addGestureRecognizer(removed)
        var observed = MapHomeObservedGestures<UIPanGestureRecognizer>()
        let action = #selector(GestureTarget.handle)

        observed.refresh(found: MapHomeMapGestures.pans(in: view), target: target, action: action)
        observed.refresh(found: MapHomeMapGestures.pans(in: view), target: target, action: action)
        XCTAssertEqual(observed.gestures.count, 2)

        child.removeGestureRecognizer(removed)
        observed.refresh(found: MapHomeMapGestures.pans(in: view), target: target, action: action)
        XCTAssertEqual(observed.gestures.map(ObjectIdentifier.init), [ObjectIdentifier(kept)])

        observed.removeAll(target: target, action: action)
        XCTAssertTrue(observed.gestures.isEmpty)
    }

    func testCameraGesturesAreOnlyPinchAndRotation() {
        let view = UIView()
        view.addGestureRecognizer(UIPanGestureRecognizer())
        view.addGestureRecognizer(UITapGestureRecognizer())
        view.addGestureRecognizer(UIPinchGestureRecognizer())
        view.addGestureRecognizer(UIRotationGestureRecognizer())
        XCTAssertEqual(MapHomeMapGestures.camera(in: view).count, 2)
    }

    func testAirPodsServiceStopsCleanlyWithoutRoute() {
        let service = AirPodsActivityService()
        service.start { _ in }
        XCTAssertEqual(service.stop(), [])
    }

    func testMarkerLayerHidesUnrevealedAndOffscreenAndMovesOthers() throws {
        let layer = MapHomeCoordinatorMarkerLayer()
        let now = Date(timeIntervalSince1970: 1_000)
        layer.update([
            pawprint("past", revealsAt: now.addingTimeInterval(-1)),
            pawprint("future", revealsAt: now.addingTimeInterval(1)),
            pawprint("predicted", revealsAt: nil),
            pawprint("offscreen", revealsAt: nil),
        ])
        let sublayers = try XCTUnwrap(layer.host.sublayers)
        XCTAssertEqual(sublayers.count, 4)

        let point = CGPoint(x: 10, y: 20)
        layer.apply(points: ["past": point, "future": point, "predicted": point], at: now)
        XCTAssertEqual(sublayers.map(\.isHidden), [false, true, false, true])
        XCTAssertEqual(sublayers[0].position, point)

        layer.apply(points: ["past": point, "future": point], at: now.addingTimeInterval(2))
        XCTAssertFalse(sublayers[1].isHidden, "재생 시각이 지나면 보인다")
        XCTAssertTrue(sublayers[2].isHidden, "투영에서 빠지면 숨긴다")
    }

    func testMarkerLayerKeepsDrawOrderSharesGlyphsAndEmpties() throws {
        let layer = MapHomeCoordinatorMarkerLayer()
        layer.update([pawprint("a", revealsAt: nil), pawprint("b", revealsAt: nil), pawprint("c", revealsAt: nil, isSelected: true)])
        let sublayers = try XCTUnwrap(layer.host.sublayers)
        XCTAssertTrue((sublayers[0].contents as AnyObject) === (sublayers[1].contents as AnyObject))
        XCTAssertFalse((sublayers[0].contents as AnyObject) === (sublayers[2].contents as AnyObject))
        XCTAssertGreaterThan(sublayers[2].bounds.width, sublayers[0].bounds.width)
        XCTAssertFalse(layer.isEmpty)

        layer.update([])
        XCTAssertTrue(layer.isEmpty)
        XCTAssertEqual(layer.host.sublayers?.count ?? 0, 0)
    }

    func testLivePlaybackViewportRevisionMovesOnlyOnRealChange() {
        let store = MapHomeVectorViewportStore()
        let first = viewport(x: 1), second = viewport(x: 2)
        store.livePlaybackViewport = first
        let revision = store.liveFrameRevision
        store.livePlaybackViewport = first
        XCTAssertEqual(store.liveFrameRevision, revision, "카메라가 멈추면 오버레이를 다시 평가하지 않는다")
        store.livePlaybackViewport = second
        XCTAssertEqual(store.liveFrameRevision, revision + 1)
    }

    /// 앱 카탈로그에 사본이 없어도 잠금화면 검증·고양이 그림이 위젯의 아틀라스를 찾아야 한다.
    func testCatAtlasResolvesFromWidgetBundle() {
        XCTAssertTrue(TaptionCatAtlasBundle.current.bundlePath.hasSuffix("TaptionPlanWidget.appex"))
        XCTAssertNotNil(UIImage(named: "TaptionCatAtlasCow", in: TaptionCatAtlasBundle.current, with: nil))
        XCTAssertNil(UIImage(named: "TaptionCatAtlasCow"), "앱에는 사본이 없다")
    }

    private func pawprint(_ id: String, revealsAt: Date?, isSelected: Bool = false) -> MapHomeLayerPawprint {
        MapHomeLayerPawprint(id: id, color: .red, isSelected: isSelected, angleDegrees: 30, revealsAt: revealsAt)
    }

    private func viewport(x: CGFloat) -> MapHomeVectorViewport {
        MapHomeVectorViewport(
            center: .init(latitude: 37, longitude: 127),
            span: .init(latitudeDelta: 0.1, longitudeDelta: 0.1),
            cameraDistance: 500,
            heading: 0,
            pitch: 0,
            markerPoints: ["a": CGPoint(x: x, y: 0)]
        )
    }

    private func write(_ plist: [String: Any], format: PropertyListSerialization.PropertyListFormat) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0).write(to: file)
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }
}

private final class GestureTarget: NSObject {
    @objc func handle() {}
}
