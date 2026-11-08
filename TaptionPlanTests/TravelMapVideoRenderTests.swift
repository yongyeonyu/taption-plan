import AVFoundation
import CoreLocation
import XCTest
@testable import TaptionPlan

/// TRV1108A01: 도시 여행 지도 영상과 기존 재생 영상의 그릇이 세로(9:16) MP4인지 실제 파일로 확인한다.
@MainActor
final class TravelMapVideoRenderTests: XCTestCase {
    private func trip() -> TravelMapTrip {
        var trip = TravelMapTrip()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for (name, latitude, longitude) in [
            ("서울", 37.5683, 126.9978), ("전주", 35.8314, 127.1404), ("경주", 35.8428, 129.2117),
            ("부산", 35.097, 129.0081), ("제주", 33.5101, 126.5219),
        ] {
            trip.append(name: name, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), now: start)
        }
        trip.stops[4].arrivalMode = .flight
        return trip
    }

    private func palette() -> TravelMapPalette {
        TravelMapPalette.make(bar: TaptionBarPalette(["#3E3320", "#EE8A5E", "#F3C766", "#D9694F", "#62B7A6", "#E7708F", "#9CC6E8", "#FBF6EA", "#8A5A3C", "#B9A98F"]), isDark: false)
    }

    /// ISO 기반 MP4는 `ftyp` 상자가 맨 앞에 있고, QuickTime(.mov)의 주 브랜드는 `qt  `이다.
    private func assertMP4(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let head = try FileHandle(forReadingFrom: url).read(upToCount: 12) ?? Data()
        XCTAssertEqual(String(decoding: head[4..<8], as: UTF8.self), "ftyp", file: file, line: line)
        XCTAssertNotEqual(String(decoding: head[8..<12], as: UTF8.self), "qt  ", file: file, line: line)
    }

    private func assertVertical916Video(_ url: URL, width: Int, height: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(Int(size.width), width, file: file, line: line)
        XCTAssertEqual(Int(size.height), height, file: file, line: line)
        XCTAssertEqual(Int(size.width) * 16, Int(size.height) * 9, file: file, line: line)
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        let codec = CMFormatDescriptionGetMediaSubType(format)
        XCTAssertTrue(
            [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC].contains(codec),
            "codec \(codec)", file: file, line: line
        )
    }

    func testDefaultOutputIsFullHDVertical() {
        let renderer = TravelMapVideoRenderer(trip: trip(), language: .korean, palette: palette())
        XCTAssertEqual(renderer.pixelWidth, 1_080)
        XCTAssertEqual(renderer.pixelHeight, 1_920)
    }

    func testShortRenderWritesVertical916MP4() async throws {
        let renderer = TravelMapVideoRenderer(
            trip: trip(), language: .korean, palette: palette(),
            size: CGSize(width: 90, height: 160), scale: 2
        )
        renderer.fps = 4
        renderer.codec = .h264
        renderer.bitRate = 400_000
        var last = 0.0
        let url = try await renderer.render { last = $0 }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.pathExtension, "mp4")
        XCTAssertEqual(last, 1, accuracy: 1e-9)
        try assertMP4(url)
        try await assertVertical916Video(url, width: 180, height: 320)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, Double(renderer.plan.frameCount(fps: 4)) / 4, accuracy: 0.3)
    }

    /// 기존 재생 영상과 여러 날 영상이 쓰는 쓰기 도구도 MP4로 쓴다. 사진 앱 저장은 이 파일을 그대로 넘긴다.
    func testPlaybackWriterDefaultsToMP4() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TRV-\(UUID().uuidString).mp4")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let writer = try MapHomePlaybackVideoWriter(url: url, width: 108, height: 192, fps: 10, codec: .hevc, bitRate: 300_000)
        for index in 0..<5 {
            try await writer.append(try writer.makeBuffer(), frameIndex: index)
        }
        try await writer.finish()
        try assertMP4(url)
        try await assertVertical916Video(url, width: 108, height: 192)
    }

    /// 바탕 지도가 실제로 그려진다: 육지(대구 둘레)와 바다(서해) 색이 다르고, 그 둘 모두 중간 톤이다.
    func testFrameDrawsLandAndSeaInDifferentColors() throws {
        let palette = palette()
        let renderer = TravelMapVideoRenderer(trip: trip(), language: .korean, palette: palette, scale: 1)
        // 처음 장면에는 서울 점과 정보 칸만 있어 두 점 모두 바탕 지도만 보인다.
        let image = renderer.image(atSecond: 0.5)
        let land = try pixel(image, at: renderer.scene.viewport.point(CLLocationCoordinate2D(latitude: 36.3, longitude: 128.2)))
        let sea = try pixel(image, at: renderer.scene.viewport.point(CLLocationCoordinate2D(latitude: 35.6, longitude: 125.2)))
        assertClose(land, try rgb(palette.land), "land pixel")
        assertClose(sea, try rgb(palette.water), "sea pixel")
        try saveSnapshots(renderer)
    }

    private func assertClose(_ actual: [Int], _ expected: [Int], _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(zip(actual, expected).allSatisfy { abs($0 - $1) <= 3 }, "\(message) \(actual) vs \(expected)", file: file, line: line)
    }

    private func rgb(_ color: UIColor) throws -> [Int] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
        return [r, g, b].map { Int(($0 * 255).rounded()) }
    }

    /// 한 점의 sRGB 값.
    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [Int] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let scale = image.scale
        var data = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(
            x: -point.x * scale, y: -(CGFloat(cgImage.height) - point.y * scale),
            width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)
        ))
        return [Int(data[0]), Int(data[1]), Int(data[2])]
    }

    /// `TEST_RUNNER_TRAVEL_MAP_SNAPSHOT_DIR`를 주면 장면 몇 장을 PNG로 남긴다(시뮬레이터 확인용).
    private func saveSnapshots(_ renderer: TravelMapVideoRenderer) throws {
        for (index, second) in [0.5, 3.0, 6.5, renderer.plan.totalSeconds - 0.5].enumerated() {
            let image = renderer.image(atSecond: second)
            let attachment = XCTAttachment(image: image)
            attachment.name = "travel-map-\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let folder = ProcessInfo.processInfo.environment["TRAVEL_MAP_SNAPSHOT_DIR"], let png = image.pngData() {
                try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("travel-map-\(index).png"))
            }
        }
    }
}
