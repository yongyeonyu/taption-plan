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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BGM-\(UUID().uuidString).mp4")
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

    /// 녹화 파일에 곡을 넣어도 영상 표본은 그대로이고, 곡보다 길면 반복해 끝까지 채운다(REC1105A02).
    func testMuxAddsLoopedMusicAndKeepsVideoSamples() async throws {
        let seconds = longestTrackSeconds + 4
        let recorded = try await writeVideo(seconds: seconds, music: nil)
        let muxed = try await MapHomeRecordingMusicMuxer.mux(video: recorded, music: try track())
        addTeardownBlock { try? FileManager.default.removeItem(at: muxed) }
        try await assertAudioMatchesVideo(muxed, seconds: seconds)
        let sourceCount = try await videoSampleCount(recorded)
        let muxedCount = try await videoSampleCount(muxed)
        XCTAssertEqual(muxedCount, sourceCount)
    }

    func testMuxFailureLeavesRecordingAndNoOutput() async throws {
        let notVideo = FileManager.default.temporaryDirectory.appendingPathComponent("REC-\(UUID().uuidString).mp4")
        try Data("not a video".utf8).write(to: notVideo)
        addTeardownBlock { try? FileManager.default.removeItem(at: notVideo) }
        do {
            let url = try await MapHomeRecordingMusicMuxer.mux(video: notVideo, music: try track())
            XCTFail("합성이 성공하면 안 된다: \(url)")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: notVideo.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: notVideo.deletingPathExtension().appendingPathExtension("music.mp4").path))
        }
    }

    private func videoSampleCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var count = 0
        while let sample = output.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(sample) }
        return count
    }

    func testCancelWithMusicDoesNotHang() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BGM-\(UUID().uuidString).mp4")
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

    /// 끝의 무음 꼬리를 잘라 반복하므로, 모든 곡의 반복 길이가 파일보다 짧고 마지막 표본이 들린다.
    func testLoopLengthDropsTrailingSilence() throws {
        for track in MapHomePlaybackMusicTrack.allCases {
            let url = try XCTUnwrap(track.url)
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
            let loop = try MapHomePlaybackMusicStream.audibleLength(of: file)
            let tail = Double(file.length - loop) / file.processingFormat.sampleRate
            XCTAssertLessThan(loop, file.length, track.rawValue)
            XCTAssertLessThan(tail, 2.5, "\(track.rawValue) 꼬리가 너무 길게 잘림")
            let channels = Int(file.processingFormat.channelCount)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 64))
            file.framePosition = loop - 1
            try file.read(into: buffer, frameCount: 1)
            let last = try XCTUnwrap(buffer.audioBufferList.pointee.mBuffers.mData).assumingMemoryBound(to: Float.self)
            let peak = (0..<channels).map { abs(last[$0]) }.max() ?? 0
            XCTAssertGreaterThan(peak, MapHomePlaybackMusicStream.silenceThreshold, track.rawValue)
        }
    }

    /// 이음새 근처의 표본 간 변화가 곡 안에서 나오는 변화보다 커지지 않는다.
    func testLoopSeamsDoNotClick() throws {
        for track in MapHomePlaybackMusicTrack.allCases {
            let url = try XCTUnwrap(track.url)
            let file = try AVAudioFile(forReading: url)
            let stream = try MapHomePlaybackMusicStream(url: url, durationSeconds: Double(file.length) / file.processingFormat.sampleRate * 2.2)
            let length = stream.loopFrames
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
