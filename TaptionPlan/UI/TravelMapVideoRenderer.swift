import AVFoundation
import CoreVideo
import UIKit

/// 도시 여행 지도 영상(TRV1108A01). 앱 안 Natural Earth 바탕 지도 위에 도시·구간·날짜를 코어 그래픽으로 그려
/// 세로(9:16) MP4로 쓴다. 지도 타일·지도 서비스를 쓰지 않고, 창 없이 그려서 시험에서도 돌아간다.
/// 카메라가 움직이지 않으므로 바탕 지도는 한 번만 그려 두고 프레임마다 그 위에 선과 글자만 얹는다.
@MainActor
final class TravelMapVideoRenderer {
    static let defaultFPS = 30
    static let defaultSize = CGSize(width: 360, height: 640)

    let trip: TravelMapTrip
    let plan: TravelMapVideoPlan
    let scene: TravelMapVideoScene
    let size: CGSize
    let scale: CGFloat
    var fps = TravelMapVideoRenderer.defaultFPS
    var codec: AVVideoCodecType = .hevc
    var bitRate = 10_000_000
    /// 배경 음악. nil이면 소리 없는 영상이다.
    var music: URL?

    private let language: MapHomeLanguage
    private let palette: TravelMapPalette
    private let baseMap: TravelMapBaseMap?
    private let labels: [LabelGroup]
    private let stopDates: [String]
    private let title: String
    private let detail: String
    private var baseImage: UIImage?
    private var symbolCache: [String: UIImage] = [:]

    /// 같은 곳을 다시 들르면 이름은 한 번만 쓰고 날짜를 잇는다.
    private struct LabelGroup {
        let name: String
        let stopIndices: [Int]
        let point: CGPoint
        var rect = CGRect.zero
    }

    init(
        trip: TravelMapTrip,
        language: MapHomeLanguage,
        palette: TravelMapPalette,
        baseMap: TravelMapBaseMap? = .bundled,
        size: CGSize = TravelMapVideoRenderer.defaultSize,
        scale: CGFloat = 3
    ) {
        self.trip = trip
        self.language = language
        self.palette = palette
        self.baseMap = baseMap
        self.size = size
        self.scale = scale
        plan = TravelMapVideoPlan(legCount: max(0, trip.stops.count - 1))
        scene = TravelMapVideoScene(trip: trip, size: size)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .korean ? "ko_KR" : "en_US")
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        stopDates = trip.stops.map { formatter.string(from: $0.date) }
        var groups: [LabelGroup] = []
        for (index, stop) in trip.stops.enumerated() {
            let point = scene.stopPoints[index]
            if let existing = groups.firstIndex(where: { $0.name == stop.name && hypot($0.point.x - point.x, $0.point.y - point.y) < 4 }) {
                groups[existing] = LabelGroup(name: stop.name, stopIndices: groups[existing].stopIndices + [index], point: groups[existing].point)
            } else {
                groups.append(LabelGroup(name: stop.name, stopIndices: [index], point: point))
            }
        }
        labels = Self.placed(groups, dates: stopDates, size: size, curves: scene.legCurves)
        title = Self.routeTitle(trip: trip, width: size.width - 56)
        detail = Self.detailText(trip: trip, cityCount: groups.count, language: language, formatter: formatter)
    }

    var pixelWidth: Int { Int((size.width * scale).rounded()) }
    var pixelHeight: Int { Int((size.height * scale).rounded()) }

    // MARK: - 렌더

    /// 영상을 만들어 임시 `.mp4` 위치를 돌려준다. 취소하면 `CancellationError`.
    func render(progress: @escaping (Double) -> Void) async throws -> URL {
        guard trip.isRenderable else { throw MapHomePlaybackVideoError.empty }
        let frames = plan.frameCount(fps: fps)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BOKKI-Plan-travel-\(UUID().uuidString).mp4")
        let writer = try MapHomePlaybackVideoWriter(
            url: url, width: pixelWidth, height: pixelHeight, fps: fps, codec: codec, bitRate: bitRate,
            music: music, durationSeconds: Double(frames) / Double(fps), fileType: .mp4
        )
        let started = ProcessInfo.processInfo.systemUptime
        var reported = -1.0
        do {
            for index in 0..<frames {
                try Task.checkCancellation()
                let buffer = try writer.makeBuffer()
                draw(into: buffer, second: Double(index) / Double(fps))
                try await writer.append(buffer, frameIndex: index)
                let value = Double(index + 1) / Double(frames)
                if value - reported >= 0.01 || index == frames - 1 {
                    reported = value
                    progress(value)
                }
                // 시트의 진행 표시와 취소 단추가 멈추지 않게 한 프레임마다 양보한다.
                await Task.yield()
            }
            try await writer.finish()
        } catch {
            writer.cancel()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        let seconds = ProcessInfo.processInfo.systemUptime - started
        TaptionPlanDiagnosticsLogger.shared.record(
            "travel_map_video_render",
            fields: ["codec": codec.rawValue, "size": "\(pixelWidth)x\(pixelHeight)"],
            metrics: ["frames": Double(frames), "seconds": seconds, "stops": Double(trip.stops.count)]
        )
        return url
    }

    /// 한 프레임 그림. 미리보기와 시험이 쓴다.
    func image(atSecond second: Double) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            drawFrame(atSecond: second, context: context.cgContext)
        }
    }

    private func draw(into buffer: CVPixelBuffer, second: Double) {
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
        drawFrame(atSecond: second, context: context)
    }

    private func drawFrame(atSecond second: Double, context: CGContext) {
        let bounds = CGRect(origin: .zero, size: size)
        baseMapImage().draw(in: bounds)
        let state = plan.state(atSecond: second)
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for leg in 0..<min(state.drawnLegs, scene.legCurves.count) {
            strokeLeg(scene.legCurves[leg], mode: trip.stops[leg + 1].arrivalMode, context: context)
        }
        if let progress = state.activeProgress {
            strokeLeg(scene.partial(leg: state.drawnLegs, progress: progress), mode: trip.stops[state.drawnLegs + 1].arrivalMode, context: context)
        }
        context.restoreGState()
        drawStops(state: state, second: second, context: context)
        for leg in 0..<min(state.drawnLegs, scene.legCurves.count) {
            let curve = scene.legCurves[leg]
            drawBadge(trip.stops[leg + 1].arrivalMode, at: curve[curve.count / 2], radius: 9)
        }
        if let progress = state.activeProgress, let head = scene.partial(leg: state.drawnLegs, progress: progress).last {
            drawBadge(trip.stops[state.drawnLegs + 1].arrivalMode, at: head, radius: 12)
        }
        drawLabels(state: state)
        drawCard()
        drawAttribution()
    }

    private func baseMapImage() -> UIImage {
        if let baseImage { return baseImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            if let baseMap {
                baseMap.draw(in: context.cgContext, viewport: scene.viewport, palette: palette)
            } else {
                palette.water.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
        }
        baseImage = image
        return image
    }

    // MARK: - 구간·도시

    private func strokeLeg(_ points: [CGPoint], mode: TravelMapMode, context: CGContext) {
        guard points.count >= 2 else { return }
        let path = CGMutablePath()
        path.addLines(between: points)
        context.setLineDash(phase: 0, lengths: [])
        context.addPath(path)
        context.setStrokeColor(palette.routeHalo.cgColor)
        context.setLineWidth(6.5)
        context.strokePath()
        context.addPath(path)
        context.setStrokeColor(palette.route.cgColor)
        context.setLineWidth(3.5)
        // 비행은 땅을 지나지 않으니 점선으로 구분한다.
        if mode == .flight { context.setLineDash(phase: 0, lengths: [7, 6]) }
        context.strokePath()
    }

    private func drawStops(state: TravelMapVideoPlan.State, second: Double, context: CGContext) {
        let reached = min(state.currentStop, scene.stopPoints.count - 1)
        guard reached >= 0 else { return }
        for index in 0...reached {
            let point = scene.stopPoints[index]
            let isCurrent = index == reached && !state.isOverview
            let radius: CGFloat = isCurrent ? 7 : 5
            palette.routeHalo.setFill()
            UIBezierPath(ovalIn: CGRect(x: point.x - radius - 2, y: point.y - radius - 2, width: (radius + 2) * 2, height: (radius + 2) * 2)).fill()
            palette.city.setFill()
            UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)).fill()
            guard isCurrent else { continue }
            // 지금 도시는 퍼지는 고리로 강조한다.
            let phase = second.truncatingRemainder(dividingBy: 1.2) / 1.2
            let ring = radius + 3 + 12 * phase
            context.setStrokeColor(palette.city.withAlphaComponent(0.8 * (1 - phase)).cgColor)
            context.setLineWidth(2)
            context.setLineDash(phase: 0, lengths: [])
            context.strokeEllipse(in: CGRect(x: point.x - ring, y: point.y - ring, width: ring * 2, height: ring * 2))
        }
    }

    private func drawBadge(_ mode: TravelMapMode, at point: CGPoint, radius: CGFloat) {
        let circle = UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        palette.labelHalo.setFill()
        circle.fill()
        palette.route.setStroke()
        circle.lineWidth = 1.5
        circle.stroke()
        let icon = symbol(mode.symbolName, size: radius * 1.05)
        icon.draw(in: CGRect(x: point.x - icon.size.width / 2, y: point.y - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
    }

    private func symbol(_ name: String, size: CGFloat) -> UIImage {
        let key = "\(name)|\(size)"
        if let cached = symbolCache[key] { return cached }
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .bold)
        let image = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(palette.route, renderingMode: .alwaysOriginal) ?? UIImage()
        symbolCache[key] = image
        return image
    }

    // MARK: - 글자

    private static let nameFont = UIFont.systemFont(ofSize: 13, weight: .bold)
    private static let dateFont = UIFont.systemFont(ofSize: 10.5, weight: .semibold)

    private static func labelSize(name: String, dates: String) -> CGSize {
        let nameSize = (name as NSString).size(withAttributes: [.font: nameFont])
        let dateSize = (dates as NSString).size(withAttributes: [.font: dateFont])
        return CGSize(width: max(nameSize.width, dateSize.width), height: nameSize.height + dateSize.height)
    }

    /// 도시 이름 칸을 아래 → 위 → 오른쪽 → 왼쪽 순서로 놓아 보고, 다른 이름·도시 점·경로선과 겹치지 않는 첫 자리를 쓴다.
    private static func placed(_ groups: [LabelGroup], dates: [String], size: CGSize, curves: [[CGPoint]]) -> [LabelGroup] {
        let route = curves.flatMap { $0 }
        let dots = groups.map { CGRect(x: $0.point.x - 8, y: $0.point.y - 8, width: 16, height: 16) }
        let bounds = CGRect(x: 6, y: size.height * 0.24, width: size.width - 12, height: size.height * 0.7)
        var taken: [CGRect] = []
        return groups.map { group in
            let text = group.stopIndices.map { dates[$0] }.joined(separator: " · ")
            let box = labelSize(name: group.name, dates: text)
            let p = group.point
            let candidates = [
                CGRect(x: p.x - box.width / 2, y: p.y + 10, width: box.width, height: box.height),
                CGRect(x: p.x - box.width / 2, y: p.y - 10 - box.height, width: box.width, height: box.height),
                CGRect(x: p.x + 12, y: p.y - box.height / 2, width: box.width, height: box.height),
                CGRect(x: p.x - 12 - box.width, y: p.y - box.height / 2, width: box.width, height: box.height),
            ]
            let fits = candidates.first { rect in
                bounds.contains(rect) && !taken.contains { $0.intersects(rect) }
                    && !dots.contains { $0.intersects(rect) && !$0.contains(p) }
                    && !route.contains { rect.insetBy(dx: -2, dy: -2).contains($0) }
            }
            var placed = group
            placed.rect = fits ?? candidates[0]
            taken.append(placed.rect)
            return placed
        }
    }

    private func drawLabels(state: TravelMapVideoPlan.State) {
        let reached = state.isOverview ? trip.stops.count - 1 : state.currentStop
        for group in labels {
            let shown = group.stopIndices.filter { $0 <= reached }
            guard !shown.isEmpty else { continue }
            let isCurrent = !state.isOverview && shown.contains(state.currentStop)
            let dates = shown.map { stopDates[$0] }.joined(separator: " · ")
            let nameSize = (group.name as NSString).size(withAttributes: [.font: Self.nameFont])
            let dateSize = (dates as NSString).size(withAttributes: [.font: Self.dateFont])
            let color = isCurrent ? palette.label : palette.label.withAlphaComponent(0.85)
            drawHaloText(group.name, font: Self.nameFont, color: color, at: CGPoint(x: group.rect.midX - nameSize.width / 2, y: group.rect.minY))
            drawHaloText(dates, font: Self.dateFont, color: color.withAlphaComponent(0.8), at: CGPoint(x: group.rect.midX - dateSize.width / 2, y: group.rect.minY + nameSize.height))
        }
    }

    private func drawHaloText(_ text: String, font: UIFont, color: UIColor, at point: CGPoint) {
        let string = text as NSString
        string.draw(at: point, withAttributes: [.font: font, .foregroundColor: palette.labelHalo, .strokeColor: palette.labelHalo, .strokeWidth: 8])
        string.draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    private static let titleFont = UIFont.systemFont(ofSize: 16, weight: .bold)
    private static let detailFont = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

    /// 정보 칸: 도시 이름을 화살표로 잇고, 아래 줄에 도시 수 · 날짜 · 거리를 적는다.
    private func drawCard() {
        let titleSize = (title as NSString).size(withAttributes: [.font: Self.titleFont])
        let detailSize = (detail as NSString).size(withAttributes: [.font: Self.detailFont])
        let rect = CGRect(x: 16, y: size.height * 0.07, width: size.width - 32, height: titleSize.height + detailSize.height + 26)
        palette.card.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 14).fill()
        (title as NSString).draw(at: CGPoint(x: rect.minX + 12, y: rect.minY + 10), withAttributes: [.font: Self.titleFont, .foregroundColor: palette.cardText])
        (detail as NSString).draw(
            at: CGPoint(x: rect.minX + 12, y: rect.minY + 14 + titleSize.height),
            withAttributes: [.font: Self.detailFont, .foregroundColor: palette.cardSecondary]
        )
    }

    /// 공개 도메인이라 표기 의무는 없지만, 공유되는 영상이라 출처를 밝힌다.
    private func drawAttribution() {
        let text = "Natural Earth" as NSString
        let font = UIFont.systemFont(ofSize: 8, weight: .medium)
        let textSize = text.size(withAttributes: [.font: font])
        text.draw(at: CGPoint(x: 8, y: size.height - textSize.height - 6), withAttributes: [.font: font, .foregroundColor: palette.label.withAlphaComponent(0.7)])
    }

    /// 폭에 다 들어가면 모든 도시, 아니면 처음 → … → 끝.
    static func routeTitle(trip: TravelMapTrip, width: CGFloat) -> String {
        var ordered: [String] = []
        for stop in trip.stops where ordered.last != stop.name { ordered.append(stop.name) }
        let full = ordered.joined(separator: " → ")
        guard (full as NSString).size(withAttributes: [.font: titleFont]).width > width,
              let first = ordered.first, let last = ordered.last else { return full }
        return "\(first) → … → \(last)"
    }

    static func detailText(trip: TravelMapTrip, cityCount: Int, language: MapHomeLanguage, formatter: DateFormatter) -> String {
        var parts = [language.text("도시 \(cityCount)곳", "\(cityCount) cities")]
        if let first = trip.firstDate, let last = trip.lastDate {
            let calendar = Calendar.autoupdatingCurrent
            if calendar.isDate(first, inSameDayAs: last) {
                parts.append(formatter.string(from: first))
            } else {
                let ranged = DateFormatter()
                ranged.locale = formatter.locale
                ranged.setLocalizedDateFormatFromTemplate(calendar.isDate(first, equalTo: last, toGranularity: .year) ? "MMMd" : "yMMMd")
                parts.append("\(ranged.string(from: first)) – \(ranged.string(from: last))")
            }
        }
        parts.append(AppRegion.current.longDistanceText(meters: trip.totalMeters))
        return parts.joined(separator: " · ")
    }
}
