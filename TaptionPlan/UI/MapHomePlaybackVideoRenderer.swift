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
    /// 구동기처럼 하루 조회 자료를 한 번 만들어 프레임마다 쓴다(PRF1101A01).
    private let lookup: MapHomePlaybackLookup
    var preferredForecastLegIDs: Set<String> = []
    var expectedCoordinate: (Date) -> GeoPoint? = { _ in nil }
    var isAdaptiveZoom = true
    /// 첫 프레임 카메라 거리. 실시간 재생에서는 지금 지도 카메라 거리다.
    var initialCameraDistance: Double = MapHomeStartupCameraPolicy.distance
    /// 실시간 재생과 같은 경로 다듬기(PLY1029A07). 원본 좌표를 그대로 보려면 끈다.
    var smoothsPath = true

    init(inputs: MapHomePlaybackDriver.Inputs, projection: MapHomeWBSPlaybackProjection?) {
        self.inputs = inputs
        self.projection = projection
        lookup = MapHomePlaybackLookup(readings: inputs.readings, travel: inputs.travel, places: inputs.places)
    }

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
            lookup: lookup,
            expectedCoordinate: frame == nil ? expectedCoordinate(date) : nil
        )
        guard let point = location?.cameraCoordinate else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    /// 이 분의 목표 카메라 거리(스무딩 전).
    func targetDistance(atMinute minute: Double) -> Double {
        let date = inputs.dayStart.addingTimeInterval(minute * 60)
        let speed = lookup.speed(at: date, travel: inputs.travel)
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
    static let dayFPS = 60
    /// 여러 날 영상은 빠르게 지나가 30fps로도 부드럽고, 만드는 시간이 절반으로 준다.
    static let rangeFPS = 30
    var fps = dayFPS
    var capturesAtPlaybackSpeed = false
    /// 화면 절반 넘게 움직인 프레임만 새 타일을 끝까지 기다린다. 나머지는 이미 받은 타일로 그린다.
    nonisolated static let frameTimeout: TimeInterval = 2
    nonisolated static let smallMoveFrameTimeout: TimeInterval = 0.2
    nonisolated static let largeMoveRatio = 0.5
    /// 여러 날 영상은 재생하며 녹화하듯 타일을 오래 기다리지 않는다. 덜 받은 타일은 비어 보일 수 있다(VID1105A04).
    nonisolated static let playbackSpeedFrameTimeout: TimeInterval = 0.05
    nonisolated static let playbackSpeedLargeMoveTimeout: TimeInterval = 0.4
    static let styleTimeout: TimeInterval = 15
    static let stickmanCacheLimit = 256

    private let makeFrames: (Int) -> [MapHomePlaybackTimeline.Frame]
    private let overlay: MapHomePlaybackVideoOverlay?
    /// 지도 크기(pt). 출력 픽셀은 `size × scale`(기본 360×640pt × 3 = 1080×1920).
    let size: CGSize
    let scale: CGFloat
    var codec: AVVideoCodecType = .hevc
    var bitRate = 16_000_000
    /// 배경 음악 파일. nil이면 소리 없는 영상이다(BGM1104A02).
    var music: URL?

    private let style: MapHomeVectorStyle
    private let pitch: CGFloat
    private let heading: CLLocationDirection
    private let stickman: (Double) -> MapHomePlaybackVideoStickman?
    private var window: UIWindow?
    private var mapView: MLNMapView?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var waitToken = 0
    private var isStyleLoaded = false
    private var acceptsPartialFrame = false
    private var stickmanCache: [String: UIImage] = [:]
    private var lastCamera: (coordinate: CLLocationCoordinate2D, distance: Double)?
    private(set) var timeoutCount = 0

    init(
        style: MapHomeVectorStyle,
        timeline: MapHomePlaybackTimeline,
        size: CGSize = CGSize(width: 360, height: 640),
        scale: CGFloat = 3,
        pitch: CGFloat = 0,
        heading: CLLocationDirection = 0,
        hiddenPlaces: [MapHomeRangeTripPlan.Point] = [],
        stickman: @escaping (Double) -> MapHomePlaybackVideoStickman?
    ) {
        self.style = style
        makeFrames = { MapHomeRangeTripPlan.masked(Array(timeline.frames(fps: $0)), hiddenPlaces: hiddenPlaces) }
        overlay = nil
        self.size = size
        self.scale = scale
        self.pitch = pitch
        self.heading = heading
        self.stickman = stickman
    }

    /// 여행 영상처럼 프레임과 오버레이를 직접 주는 경우(PLR1104A01). 화랑이는 오버레이가 정한 좌표에 놓는다.
    init(
        style: MapHomeVectorStyle,
        frames: @escaping (Int) -> [MapHomePlaybackTimeline.Frame],
        overlay: MapHomePlaybackVideoOverlay,
        size: CGSize = CGSize(width: 360, height: 640),
        scale: CGFloat = 3
    ) {
        self.style = style
        makeFrames = frames
        self.overlay = overlay
        self.size = size
        self.scale = scale
        pitch = 0
        heading = 0
        stickman = { _ in nil }
    }

    var pixelWidth: Int { Int((size.width * scale).rounded()) }
    var pixelHeight: Int { Int((size.height * scale).rounded()) }

    // MARK: - 렌더

    /// 영상을 만들어 임시 `.mov` 위치를 돌려준다. 취소하면 `CancellationError`.
    func render(progress: @escaping (Double) -> Void) async throws -> URL {
        let frames = makeFrames(fps)
        guard !frames.isEmpty else { throw MapHomePlaybackVideoError.empty }
        let started = ProcessInfo.processInfo.systemUptime
        defer { tearDownMap() }
        try await prepareMap()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BOKKI-Plan-render-\(UUID().uuidString).mov")
        let writer = try MapHomePlaybackVideoWriter(
            url: url, width: pixelWidth, height: pixelHeight,
            fps: fps, codec: codec, bitRate: bitRate,
            music: music, durationSeconds: Double(frames.count) / Double(fps)
        )
        var reported = -1.0
        do {
            for (index, frame) in frames.enumerated() {
                try Task.checkCancellation()
                try await waitUntilActive()
                await placeCamera(frame)
                try Task.checkCancellation()
                let buffer = try writer.makeBuffer()
                draw(into: buffer, minute: frame.minute, videoSeconds: Double(index) / Double(fps))
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
        if !isStyleLoaded {
            let loaded = await wait(timeout: Self.styleTimeout)
            try Task.checkCancellation()
            if !loaded { throw MapHomePlaybackVideoError.mapLoadFailed }
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
        let timeout = Self.frameTimeout(from: lastCamera, to: (coordinate, frame.cameraDistance), atPlaybackSpeed: capturesAtPlaybackSpeed)
        acceptsPartialFrame = capturesAtPlaybackSpeed && timeout == Self.playbackSpeedFrameTimeout
        lastCamera = (coordinate, frame.cameraDistance)
        mapView.setCamera(
            MLNMapCamera(lookingAtCenter: coordinate, altitude: frame.cameraDistance, pitch: pitch, heading: heading),
            animated: false
        )
        mapView.triggerRepaint()
        if !(await wait(timeout: timeout)) { timeoutCount += 1 }
    }

    /// 첫 프레임, 크게 옮긴 프레임, 줌이 크게 바뀐 프레임만 오래 기다린다.
    nonisolated static func frameTimeout(
        from previous: (coordinate: CLLocationCoordinate2D, distance: Double)?,
        to next: (coordinate: CLLocationCoordinate2D, distance: Double),
        atPlaybackSpeed: Bool = false
    ) -> TimeInterval {
        guard let previous, previous.distance > 0, next.distance > 0 else { return frameTimeout }
        let moved = CLLocation(latitude: previous.coordinate.latitude, longitude: previous.coordinate.longitude)
            .distance(from: CLLocation(latitude: next.coordinate.latitude, longitude: next.coordinate.longitude))
        let zoomChange = abs(log2(next.distance / previous.distance))
        let isLargeMove = moved / next.distance > largeMoveRatio || zoomChange > largeMoveRatio
        if atPlaybackSpeed { return isLargeMove ? playbackSpeedLargeMoveTimeout : playbackSpeedFrameTimeout }
        return isLargeMove ? frameTimeout : smallMoveFrameTimeout
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

    /// 취소되면 시간 초과를 기다리지 않고 바로 끝난다.
    private func wait(timeout: TimeInterval) async -> Bool {
        await withTaskCancellationHandler {
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
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.finishWait(token: nil, rendered: false) }
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
        guard fullyRendered || acceptsPartialFrame, isStyleLoaded else { return }
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
        if let overlay, let mapView {
            overlay.drawBelowMarker(atSecond: videoSeconds, mapView: mapView, size: size, context: context)
            drawOverlayStickman(overlay, mapView: mapView, videoSeconds: videoSeconds)
            overlay.drawAboveMarker(atSecond: videoSeconds, size: size)
        } else {
            drawStickman(minute: minute, videoSeconds: videoSeconds)
        }
        drawAttribution()
    }

    /// 공유되는 영상이라 지도 출처를 화면에 직접 넣는다(지도 출처 단추는 영상에 나오지 않는다).
    private func drawAttribution() {
        let text = "© OpenFreeMap © OpenMapTiles © OpenStreetMap" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .medium),
            .foregroundColor: UIColor.white,
            .shadow: {
                let shadow = NSShadow()
                shadow.shadowColor = UIColor.black.withAlphaComponent(0.7)
                shadow.shadowBlurRadius = 2
                shadow.shadowOffset = .zero
                return shadow
            }(),
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: 8, y: size.height - textSize.height - 6), withAttributes: attributes)
    }

    private func drawOverlayStickman(_ overlay: MapHomePlaybackVideoOverlay, mapView: MLNMapView, videoSeconds: Double) {
        guard let state = overlay.stickman(atSecond: videoSeconds),
              let coordinate = overlay.markerCoordinate(atSecond: videoSeconds) else { return }
        let image = stickmanImage(state, phase: Self.animationPhase(state, videoSeconds: videoSeconds))
        let point = mapView.convert(coordinate, toPointTo: mapView)
        let offset = MapHomeStickmanAnnotationLayout.centerOffset
        image.draw(in: CGRect(
            x: point.x + offset.x - image.size.width / 2,
            y: point.y + offset.y - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        ))
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
        let side = MapHomeStickmanMarker.size.width * 2
        let renderer = ImageRenderer(content:
            MapHomeStickmanMarker(
                action: state.action,
                animationPhase: phase,
                routePhase: state.isForecast ? .forecast : .actual,
                speedMetersPerSecond: state.speedMetersPerSecond,
                equippedAccessoryID: state.equippedAccessoryID
            )
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
/// 음악을 주면 오디오 트랙을 더한다. 음악은 전용 큐에서 들어가 프레임 경로를 막지 않는다.
@MainActor
final class MapHomePlaybackVideoWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let fps: Int
    private var musicFeeder: MapHomePlaybackMusicFeeder?
    private var frameCount = 0

    init(
        url: URL, width: Int, height: Int, fps: Int, codec: AVVideoCodecType, bitRate: Int,
        music: URL? = nil, durationSeconds: Double = 0
    ) throws {
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
        if let music { try addMusic(music, durationSeconds: durationSeconds) }
        guard writer.startWriting() else { throw failure() }
        writer.startSession(atSourceTime: .zero)
        musicFeeder?.start()
    }

    private func addMusic(_ url: URL, durationSeconds: Double) throws {
        let stream = try MapHomePlaybackMusicStream(url: url, durationSeconds: durationSeconds)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: stream.format.sampleRate,
            AVNumberOfChannelsKey: stream.format.channelCount,
            AVEncoderBitRateKey: 192_000,
        ])
        audio.expectsMediaDataInRealTime = false
        guard writer.canAdd(audio) else { throw MapHomePlaybackVideoError.writerFailed("cannot add music") }
        writer.add(audio)
        musicFeeder = MapHomePlaybackMusicFeeder(input: audio, stream: stream)
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
            // 쓰기가 실패하면 준비 상태가 영영 오지 않는다.
            guard writer.status == .writing else { throw failure() }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let time = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
        guard adaptor.append(buffer, withPresentationTime: time) else { throw failure() }
        frameCount = frameIndex + 1
    }

    func finish() async throws {
        input.markAsFinished()
        try await finishMusic()
        let writer = writer
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw failure() }
    }

    /// 음악을 끝까지 넣고, AAC 묶음 단위로 남는 꼬리를 영상 길이에 맞춰 자른다.
    private func finishMusic() async throws {
        guard let musicFeeder else { return }
        while musicFeeder.isRunning {
            // 쓰기가 실패하면 음악 차례가 영영 오지 않는다.
            guard writer.status == .writing else { throw failure() }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        if let reason = musicFeeder.failure { throw MapHomePlaybackVideoError.writerFailed(reason) }
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(fps)))
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
    }

    private func failure() -> MapHomePlaybackVideoError {
        .writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
    }
}
