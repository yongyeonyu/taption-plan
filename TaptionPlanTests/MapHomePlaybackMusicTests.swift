import AVFoundation
import XCTest
@testable import TaptionPlan

/// BGM1104A02: 재생 영상의 배경 음악. 지도 없이 쓰기 도구에 작은 프레임을 넣어 시험한다.
@MainActor
final class MapHomePlaybackMusicTests: XCTestCase {
    private let fps = 10
    private let longestTrackSeconds = 66.0

    private func track() throws -> URL {
        try XCTUnwrap(MapHomePlaybackMusicTrack.sunnyStroll.url)
    }

    private func writeVideo(seconds: Double, music: URL?) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BGM-\(UUID().uuidString).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let writer = try MapHomePlaybackVideoWriter(
            url: url, width: 64, height: 64, fps: fps, codec: .h264, bitRate: 200_000,
            music: music, durationSeconds: seconds
        )
        for index in 0..<Int(seconds * Double(fps)) {
            try await writer.append(try writer.makeBuffer(), frameIndex: index)
        }
        try await writer.finish()
        return url
    }

    private func assertAudioMatchesVideo(_ url: URL, seconds: Double) async throws {
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 1)
        let audioRange = try await XCTUnwrap(audio.first).load(.timeRange)
        let videoRange = try await XCTUnwrap(video.first).load(.timeRange)
        XCTAssertEqual(videoRange.duration.seconds, seconds, accuracy: 0.11)
        XCTAssertEqual(audioRange.end.seconds, videoRange.end.seconds, accuracy: 0.05)
        XCTAssertEqual(audioRange.duration.seconds, seconds, accuracy: 0.11)
    }

    func testEveryTrackIsInAppBundleWithUniqueTitle() {
        let tracks = MapHomePlaybackMusicTrack.allCases
        XCTAssertEqual(tracks.count, 10)
        for track in tracks { XCTAssertNotNil(track.url, track.rawValue) }
        XCTAssertEqual(Set(tracks.map { $0.title(.english) }).count, 10)
    }

    func testStoredSelection() {
        XCTAssertNil(MapHomePlaybackMusicTrack.stored(MapHomePlaybackMusicTrack.noneID))
        XCTAssertEqual(MapHomePlaybackMusicTrack.stored(MapHomePlaybackMusicTrack.defaultID), MapHomePlaybackMusicTrack.allCases.first)
        XCTAssertEqual(MapHomePlaybackMusicTrack.stored("12-cat-parade"), .catParade)
        XCTAssertEqual(MapHomePlaybackMusicTrack.stored("removed-song"), .sunnyStroll)
    }

    func testShortVideoCutsTrackToVideoLength() async throws {
        let url = try await writeVideo(seconds: 5, music: try track())
        try await assertAudioMatchesVideo(url, seconds: 5)
    }

    func testVideoLongerThanTrackLoopsToVideoLength() async throws {
        let url = try await writeVideo(seconds: longestTrackSeconds + 4, music: try track())
        try await assertAudioMatchesVideo(url, seconds: longestTrackSeconds + 4)
    }

    func testNoMusicHasNoAudioTrack() async throws {
        let url = try await writeVideo(seconds: 2, music: nil)
        let audio = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty)
    }

    func testCancelWithMusicDoesNotHang() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BGM-\(UUID().uuidString).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let writer = try MapHomePlaybackVideoWriter(
            url: url, width: 64, height: 64, fps: fps, codec: .h264, bitRate: 200_000,
            music: try track(), durationSeconds: 5
        )
        writer.cancel()
    }

    private func drain(_ stream: MapHomePlaybackMusicStream, visit: (UnsafeBufferPointer<Float>) -> Void) throws {
        while let buffer = try stream.nextBuffer() {
            let channels = Int(buffer.format.channelCount)
            let pointer = try XCTUnwrap(buffer.audioBufferList.pointee.mBuffers.mData).assumingMemoryBound(to: Float.self)
            visit(UnsafeBufferPointer(start: pointer, count: Int(buffer.frameLength) * channels))
        }
    }

    func testStreamFillsDurationAndEndsInSilence() throws {
        let stream = try MapHomePlaybackMusicStream(url: try track(), durationSeconds: 3)
        var samples: [Float] = []
        try drain(stream) { samples += $0 }
        XCTAssertEqual(stream.producedFrames, stream.totalFrames)
        XCTAssertEqual(stream.totalFrames, AVAudioFramePosition(3 * stream.format.sampleRate))
        XCTAssertGreaterThan(samples.prefix(44_100).map(abs).max() ?? 0, 0.01)
        XCTAssertLessThan(samples.suffix(8).map(abs).max() ?? 1, 0.001)
    }

    func testFadeGainReachesZeroOnlyInsideFade() {
        XCTAssertEqual(MapHomePlaybackMusicStream.fadeGain(frame: 0, total: 1_000, fadeFrames: 100), 1)
        XCTAssertEqual(MapHomePlaybackMusicStream.fadeGain(frame: 899, total: 1_000, fadeFrames: 100), 1)
        XCTAssertEqual(MapHomePlaybackMusicStream.fadeGain(frame: 949, total: 1_000, fadeFrames: 100), 0.25, accuracy: 0.01)
        XCTAssertEqual(MapHomePlaybackMusicStream.fadeGain(frame: 999, total: 1_000, fadeFrames: 100), 0)
    }

    /// 이음새 근처의 표본 간 변화가 곡 안에서 나오는 변화보다 커지지 않는다.
    func testLoopSeamsDoNotClick() throws {
        for track in MapHomePlaybackMusicTrack.allCases {
            let url = try XCTUnwrap(track.url)
            let file = try AVAudioFile(forReading: url)
            let length = file.length
            let stream = try MapHomePlaybackMusicStream(url: url, durationSeconds: Double(length) / file.processingFormat.sampleRate * 2.2)
            let channels = Int(stream.format.channelCount)
            var previous = [Float](repeating: 0, count: channels)
            var frame: AVAudioFramePosition = 0
            var bodyJump: Float = 0, seamJump: Float = 0
            let seam = MapHomePlaybackMusicStream.seamFrames
            let firstSeam = (length - seam)...(length + 64)
            let secondSeam = (2 * length - 2 * seam)...(2 * length - seam + 64)
            try drain(stream) { samples in
                for index in stride(from: 0, to: samples.count, by: channels) {
                    for channel in 0..<channels {
                        let jump = abs(samples[index + channel] - previous[channel])
                        previous[channel] = samples[index + channel]
                        if firstSeam.contains(frame) || secondSeam.contains(frame) {
                            seamJump = max(seamJump, jump)
                        } else if frame > 0, frame < length - seam {
                            bodyJump = max(bodyJump, jump)
                        }
                    }
                    frame += 1
                }
            }
            XCTAssertGreaterThan(bodyJump, 0, track.rawValue)
            XCTAssertLessThanOrEqual(seamJump, bodyJump, track.rawValue)
        }
    }
}
