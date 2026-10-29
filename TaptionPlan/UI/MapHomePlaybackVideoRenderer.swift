import AVFoundation
import CoreLocation
import CoreVideo
@preconcurrency import MapLibre
import SwiftUI
import UIKit

/// 하루 재생을 영상 시간 기준으로 미리 계산한다(VID1029A01).
///
/// 실시간 구동기(`MapHomePlaybackDriver`)와 같은 입력·같은 배속 규칙을 쓰되, 벽시계 대신
/// 프레임마다 정확히 `1/fps`초씩 재생 시간을 전진시킨다. 줌 스무딩도 재생 시간으로 돌려
/// 같은 입력이면 언제 돌려도 같은 프레임이 나온다.
struct MapHomePlaybackTimeline {
    typealias Frame = (minute: Double, coordinate: CLLocationCoordinate2D?, cameraDistance: Double)

    /// 1/fps초 누적 오차로 끝에서 프레임이 하나 더 생기지 않게 하는 여유(분).
    static let endTolerance = 0.000_001

    let inputs: MapHomePlaybackDriver.Inputs
    var projection: MapHomeWBSPlaybackProjection?
    var preferredForecastLegIDs: Set<String> = []
    var expectedCoordinate: (Date) -> GeoPoint? = { _ in nil }
    var isAdaptiveZoom = true
    /// 첫 프레임 카메라 거리. 실시간 재생에서는 지금 지도 카메라 거리다.
    var initialCameraDistance: Double = MapHomeStartupCameraPolicy.distance
    /// 실시간 재생과 같은 경로 다듬기(PLY1029A07). 원본 좌표를 그대로 보려면 끈다.
    var smoothsPath = true

    var endMinute: Double { min(inputs.endMinute, 1_440) }

    func frames(fps: Int) -> some Sequence<Frame> {
        Frames(timeline: self, fps: max(1, fps))
    }

    /// 실시간 구동기와 같은 배속 규칙으로 분을 전진시킨다.
    func nextMinute(after minute: Double, elapsedSeconds: TimeInterval) -> Double {
        min(
            MapHomeDayPlaybackMath.advancedMinute(
                from: minute,
                elapsedSeconds: elapsedSeconds,
                normalizedMovingRanges: inputs.movingRanges
            ),
            endMinute
        )
    }

    /// 이 분의 화랑이(=카메라 중심) 좌표. 구동기와 같은 `resolveOrGap`에 같은 다듬기를 씌운다.
    func coordinate(atMinute minute: Double) -> CLLocationCoordinate2D? {
        let date = inputs.dayStart.addingTimeInterval(minute * 60)
        guard smoothsPath else { return rawCoordinate(at: date) }
        return MapHomePlaybackDriver.smoothed(at: date, position: rawCoordinate(at:))
    }

    private func rawCoordinate(at date: Date) -> CLLocationCoordinate2D? {
        let frame = projection?.frame(at: date, preferredForecastLegIDs: preferredForecastLegIDs)
        let location = MapHomePlaybackLocation.resolveOrGap(
            at: date,
            frame: frame,
            normalizedReadings: inputs.readings,
            travel: inputs.travel,
            places: inputs.places,
            expectedCoordinate: frame == nil ? expectedCoordinate(date) : nil
        )
        guard let point = location?.cameraCoordinate else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    /// 이 분의 목표 카메라 거리(스무딩 전).
    func targetDistance(atMinute minute: Double) -> Double {
        let date = inputs.dayStart.addingTimeInterval(minute * 60)
        let speed = MapHomePlaybackSpeed.speed(at: date, travel: inputs.travel, readings: inputs.readings)
        return inputs.zoomPlan.targetDistance(atMinute: minute, speedMetersPerSecond: speed)
    }

    struct Frames: Sequence {
        let timeline: MapHomePlaybackTimeline
        let fps: Int

        func makeIterator() -> Iterator { Iterator(timeline: timeline, fps: fps) }
    }

    struct Iterator: IteratorProtocol {
        let timeline: MapHomePlaybackTimeline
        let step: TimeInterval
        private var minute: Double
        private var distance: Double
        private var index = 0
        private var isFinished: Bool
        /// 매 순회마다 새로 만든다. 그래서 두 번 돌려도 결과가 같다.
        private let smoother = MapHomePlaybackZoomSmoother()

        init(timeline: MapHomePlaybackTimeline, fps: Int) {
            self.timeline = timeline
            step = 1 / Double(fps)
            minute = timeline.inputs.startMinute
            distance = timeline.initialCameraDistance
            isFinished = timeline.inputs.startMinute >= timeline.endMinute
        }

        mutating func next() -> Frame? {
            guard !isFinished else { return nil }
            minute = timeline.nextMinute(after: minute, elapsedSeconds: step)
            if minute >= timeline.endMinute - MapHomePlaybackTimeline.endTolerance {
                minute = timeline.endMinute
                isFinished = true
            }
            index += 1
            let coordinate = timeline.coordinate(atMinute: minute)
            advanceDistance(hasCoordinate: coordinate != nil)
            return (minute, coordinate, distance)
        }

        /// 좌표가 없으면 지도가 프레임을 무시하므로 카메라 거리도 그대로 둔다(구동기와 같다).
        private mutating func advanceDistance(hasCoordinate: Bool) {
            guard timeline.isAdaptiveZoom else { return }
            let next = smoother.next(
                current: distance,
                target: timeline.targetDistance(atMinute: minute),
                uptime: Double(index) * step
            )
            if hasCoordinate { distance = next }
        }
    }
}

/// 영상 속 화랑이 상태. 분마다 부모가 정한다.
struct MapHomePlaybackVideoStickman: Hashable {
    var action: MapHomeStickmanAction
    var isForecast = false
    var speedMetersPerSecond: Double?
    var equippedAccessoryID: String?
}

enum MapHomePlaybackVideoError: Error {
    case empty
    case noScene
    case mapLoadFailed
    case writerFailed(String)
}

/// 재생을 화면 녹화 대신 앱 안에서 60fps 고정으로 한 프레임씩 그려 영상으로 만든다(VID1029A01).
///
/// 숨은 창에 둔 지도에 카메라를 놓고, 타일까지 다 그려진 프레임을 기다렸다가 캡처한다.
/// 기기 부하와 상관없이 프레임이 빠지지 않는다. 화랑이는 화면 정중앙에 고정하고 지도가 움직인다.
@MainActor
final class MapHomePlaybackVideoRenderer: NSObject, @preconcurrency MLNMapViewDelegate {
    static let fps = 60
    static let frameTimeout: TimeInterval = 2
    static let styleTimeout: TimeInterval = 15
    static let stickmanCacheLimit = 256

    let timeline: MapHomePlaybackTimeline
    /// 지도 크기(pt). 출력 픽셀은 `size × scale`(기본 360×640pt × 3 = 1080×1920).
    let size: CGSize
    let scale: CGFloat
    var codec: AVVideoCodecType = .hevc
    var bitRate = 16_000_000

    private let style: MapHomeVectorStyle
    private let pitch: CGFloat
    private let heading: CLLocationDirection
    private let stickman: (Double) -> MapHomePlaybackVideoStickman?
    private var window: UIWindow?
    private var mapView: MLNMapView?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var waitToken = 0
    private var isStyleLoaded = false
    private var stickmanCache: [String: UIImage] = [:]
    private var lastCamera: (coordinate: CLLocationCoordinate2D, distance: Double)?
    private var timeoutCount = 0

    init(
        style: MapHomeVectorStyle,
        timeline: MapHomePlaybackTimeline,
        size: CGSize = CGSize(width: 360, height: 640),
        scale: CGFloat = 3,
        pitch: CGFloat = 0,
        heading: CLLocationDirection = 0,
        stickman: @escaping (Double) -> MapHomePlaybackVideoStickman?
    ) {
        self.style = style
        self.timeline = timeline
        self.size = size
        self.scale = scale
        self.pitch = pitch
        self.heading = heading
        self.stickman = stickman
    }

    var pixelWidth: Int { Int((size.width * scale).rounded()) }
    var pixelHeight: Int { Int((size.height * scale).rounded()) }

    // MARK: - 렌더

    /// 영상을 만들어 임시 `.mov` 위치를 돌려준다. 취소하면 `CancellationError`.
    func render(progress: @escaping (Double) -> Void) async throws -> URL {
        let frames = Array(timeline.frames(fps: Self.fps))
        guard !frames.isEmpty else { throw MapHomePlaybackVideoError.empty }
        let started = ProcessInfo.processInfo.systemUptime
        defer { tearDownMap() }
        try await prepareMap()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BOKKI-Plan-render-\(UUID().uuidString).mov")
        let writer = try MapHomePlaybackVideoWriter(
            url: url, width: pixelWidth, height: pixelHeight,
            fps: Self.fps, codec: codec, bitRate: bitRate
        )
        var reported = -1.0
        do {
            for (index, frame) in frames.enumerated() {
                try Task.checkCancellation()
                try await waitUntilActive()
                await placeCamera(frame)
                let buffer = try writer.makeBuffer()
                draw(into: buffer, minute: frame.minute, videoSeconds: Double(index) / Double(Self.fps))
                try await writer.append(buffer, frameIndex: index)
                let value = Double(index + 1) / Double(frames.count)
                if value - reported >= 0.005 || index == frames.count - 1 {
                    reported = value
                    progress(value)
                }
            }
            try await writer.finish()
        } catch {
            writer.cancel()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        logFinished(frames: frames.count, started: started)
        return url
    }

    /// 사진 앱 권한을 묻고 저장한다. 녹화 저장과 같은 도우미를 쓴다.
    static func saveToPhotos(_ url: URL) async -> Bool {
        guard await MapHomeScreenRecordingStore.requestPhotoAddAccess() else { return false }
        return await MapHomeScreenRecordingStore.saveToPhotos(url)
    }

    // MARK: - 숨은 지도

    /// MapLibre는 창에 붙어 있어야 그린다. 앱 창 뒤(한 단계 아래)에 불투명한 창을 두어 사용자에게는 보이지 않게 한다.
    private func prepareMap() async throws {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { throw MapHomePlaybackVideoError.noScene }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.isUserInteractionEnabled = false
        let root = UIViewController()
        window.rootViewController = root
        let mapView = makeMapView()
        root.view.addSubview(mapView)
        window.isHidden = false
        self.window = window
        self.mapView = mapView
        if !isStyleLoaded, !(await wait(timeout: Self.styleTimeout)) {
            throw MapHomePlaybackVideoError.mapLoadFailed
        }
    }

    private func makeMapView() -> MLNMapView {
        let mapView = MLNMapView(frame: CGRect(origin: .zero, size: size), styleJSON: style.json)
        mapView.delegate = self
        mapView.showsCompassView = false
        mapView.showsLogoView = false
        mapView.showsAttributionButton = false
        mapView.minimumZoomLevel = 2
        mapView.maximumZoomLevel = 20
        mapView.preferredFramesPerSecond = .maximum
        return mapView
    }

    private func tearDownMap() {
        finishWait(token: nil, rendered: false)
        mapView?.delegate = nil
        mapView?.removeFromSuperview()
        window?.isHidden = true
        mapView = nil
        window = nil
        lastCamera = nil
    }

    /// 백그라운드에서는 지도가 그리지 않는다(Metal도 금지). 앱이 돌아올 때까지 멈춘다.
    private func waitUntilActive() async throws {
        while UIApplication.shared.applicationState != .active {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// 카메라를 놓고, 바뀌었으면 타일까지 다 그려진 프레임을 기다린다.
    private func placeCamera(_ frame: MapHomePlaybackTimeline.Frame) async {
        guard let mapView, let coordinate = frame.coordinate else { return }
        if let lastCamera, Self.isSame(lastCamera, (coordinate, frame.cameraDistance)) { return }
        lastCamera = (coordinate, frame.cameraDistance)
        mapView.setCamera(
            MLNMapCamera(lookingAtCenter: coordinate, altitude: frame.cameraDistance, pitch: pitch, heading: heading),
            animated: false
        )
        mapView.triggerRepaint()
        if !(await wait(timeout: Self.frameTimeout)) { timeoutCount += 1 }
    }

    private static func isSame(
        _ lhs: (coordinate: CLLocationCoordinate2D, distance: Double),
        _ rhs: (coordinate: CLLocationCoordinate2D, distance: Double)
    ) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && abs(lhs.distance - rhs.distance) < 0.01
    }

    // MARK: - 렌더 대기

    private func wait(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            finishWait(token: nil, rendered: false)
            waitToken &+= 1
            let token = waitToken
            waiter = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finishWait(token: token, rendered: false)
            }
        }
    }

    /// `token`이 nil이면 지금 기다리는 것을 끝낸다. 시간 초과 타이머는 자기 차례일 때만 끝낸다.
    private func finishWait(token: Int?, rendered: Bool) {
        guard let waiter, token == nil || token == waitToken else { return }
        self.waiter = nil
        waiter.resume(returning: rendered)
    }

    func mapViewDidFinishLoadingMap(_ mapView: MLNMapView) {
        isStyleLoaded = true
        finishWait(token: nil, rendered: true)
    }

    func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
        TaptionPlanDiagnosticsLogger.shared.record(
            "playback_video_map_failed", level: .error, fields: ["error": error.localizedDescription]
        )
        finishWait(token: nil, rendered: false)
    }

    func mapViewDidFinishRenderingFrame(_ mapView: MLNMapView, fullyRendered: Bool) {
        guard fullyRendered, isStyleLoaded else { return }
        finishWait(token: nil, rendered: true)
    }

    // MARK: - 합성

    /// 지도 캡처 위에 화랑이를 정중앙(+주석 오프셋)에 얹는다.
    private func draw(into buffer: CVPixelBuffer, minute: Double, videoSeconds: Double) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        // UIKit 좌표(왼쪽 위 원점)로 뒤집는다.
        context.translateBy(x: 0, y: CGFloat(CVPixelBufferGetHeight(buffer)))
        context.scaleBy(x: scale, y: -scale)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        let bounds = CGRect(origin: .zero, size: size)
        UIColor(Color(hex: style.backgroundHex)).setFill()
        UIRectFill(bounds)
        mapView?.drawHierarchy(in: bounds, afterScreenUpdates: true)
        drawStickman(minute: minute, videoSeconds: videoSeconds)
    }

    private func drawStickman(minute: Double, videoSeconds: Double) {
        guard let state = stickman(minute) else { return }
        let image = stickmanImage(state, phase: Self.animationPhase(state, videoSeconds: videoSeconds))
        let offset = MapHomeStickmanAnnotationLayout.centerOffset
        let center = CGPoint(x: size.width / 2 + offset.x, y: size.height / 2 + offset.y)
        image.draw(in: CGRect(
            x: center.x - image.size.width / 2,
            y: center.y - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        ))
    }

    /// 실시간 화면과 같은 걸음 속도. 영상 시간으로 넘겨 프레임마다 같은 결과가 나온다.
    static func animationPhase(_ state: MapHomePlaybackVideoStickman, videoSeconds: Double) -> Int {
        let base = TaptionLiveActivityStickmanAnimation.frameIndex(at: videoSeconds / 4, isAnimating: true)
        guard state.action.isMoving else { return base * 4 }
        let tier = MapHomeSpeedTier.tier(forMetersPerSecond: state.speedMetersPerSecond)
        return Int(Double(base) * tier.frameRateMultiplier) * 4
    }

    /// 동작·단계별로 한 번만 그려 둔다.
    private func stickmanImage(_ state: MapHomePlaybackVideoStickman, phase: Int) -> UIImage {
        let tier = MapHomeSpeedTier.tier(forMetersPerSecond: state.speedMetersPerSecond)
        let key = "\(state.action.rawValue)|\(state.isForecast)|\(tier.rawValue)|\(state.equippedAccessoryID ?? "")|\(phase)"
        if let cached = stickmanCache[key] { return cached }
        if stickmanCache.count >= Self.stickmanCacheLimit { stickmanCache.removeAll() }
        let side = MapHomeStickmanMarker.size.width * 1.5 * 2
        let renderer = ImageRenderer(content:
            MapHomeStickmanMarker(
                action: state.action,
                animationPhase: phase,
                routePhase: state.isForecast ? .forecast : .actual,
                speedMetersPerSecond: state.speedMetersPerSecond,
                equippedAccessoryID: state.equippedAccessoryID
            )
            // 지도 위 화랑이와 같은 1.5배.
            .scaleEffect(1.5)
            .frame(width: side, height: side)
        )
        renderer.scale = scale
        renderer.isOpaque = false
        let image = renderer.uiImage ?? UIImage()
        stickmanCache[key] = image
        return image
    }

    private func logFinished(frames: Int, started: TimeInterval) {
        let seconds = ProcessInfo.processInfo.systemUptime - started
        TaptionPlanDiagnosticsLogger.shared.record(
            "playback_video_render",
            fields: ["codec": codec.rawValue, "size": "\(pixelWidth)x\(pixelHeight)"],
            metrics: [
                "frames": Double(frames),
                "seconds": seconds,
                "avg_frame_ms": seconds * 1_000 / Double(max(frames, 1)),
                "timeouts": Double(timeoutCount),
            ]
        )
    }
}

/// AVAssetWriter 감싸기. 프레임 시각은 `frameIndex / fps`로 고정한다.
@MainActor
final class MapHomePlaybackVideoWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let fps: Int

    init(url: URL, width: Int, height: Int, fps: Int, codec: AVVideoCodecType, bitRate: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
        ])
        self.fps = fps
        guard writer.canAdd(input) else { throw MapHomePlaybackVideoError.writerFailed("cannot add input") }
        writer.add(input)
        guard writer.startWriting() else { throw failure() }
        writer.startSession(atSourceTime: .zero)
    }

    func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { throw failure() }
        return buffer
    }

    func append(_ buffer: CVPixelBuffer, frameIndex: Int) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let time = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
        guard adaptor.append(buffer, withPresentationTime: time) else { throw failure() }
    }

    func finish() async throws {
        input.markAsFinished()
        let writer = writer
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw failure() }
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
    }

    private func failure() -> MapHomePlaybackVideoError {
        .writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
    }
}
