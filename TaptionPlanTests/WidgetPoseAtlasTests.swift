import UIKit
import XCTest
@testable import TaptionPlan

/// 위젯·잠금화면·아일랜드·Watch 그림이 모든 자세를 담는지 잠근다(ANI1104A01).
/// 자세를 더하고 아틀라스를 다시 뽑지 않으면 줄 수·그림 내용이 어긋나 실패한다.
@MainActor
final class WidgetPoseAtlasTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// 저장소의 그림 파일을 직접 읽는 시험이라 맥(시뮬레이터)에서만 돈다. 실기기에는 소스 폴더가 없다.
    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root.path), "소스 폴더가 없는 실기기에서는 건너뛴다")
    }

    func testWidgetPoseAtlasHasRowForEveryPose() throws {
        let cell = TaptionHwarangPose.cellPixels
        for style in HwarangCoat.characters {
            let atlas = try atlasImage(style: style)
            XCTAssertEqual(atlas.width, cell.width * TaptionHwarangPose.frameCount, style)
            XCTAssertEqual(atlas.height, cell.height * TaptionHwarangPose.allCases.count, "\(style): 자세 수만큼 줄이 있어야 한다")
            for pose in TaptionHwarangPose.allCases {
                for column in 0..<TaptionHwarangPose.frameCount {
                    let rect = CGRect(x: column * cell.width, y: pose.row * cell.height, width: cell.width, height: cell.height)
                    let stored = try XCTUnwrap(atlas.cropping(to: rect).flatMap(alpha), "\(style) \(pose)")
                    XCTAssertGreaterThan(stored.filter { $0 > 0 }.count, 200, "\(style) \(pose) \(column) 칸이 비었다")
                    let fresh = try XCTUnwrap(HwarangDiagnostics.poseFrame(pose, column: column, style: style).cgImage.flatMap(alpha))
                    XCTAssertLessThan(mismatch(stored, fresh), 0.02, "\(style) \(pose) \(column): 아틀라스가 현재 장면과 다르다")
                }
            }
        }
    }

    func testWatchSpriteExistsForEveryPose() {
        for style in HwarangCoat.characters {
            for pose in TaptionHwarangPose.allCases {
                let name = "WatchCat-\(style)-\(pose.rawValue).imageset"
                let folder = root.appendingPathComponent("TaptionPlanWatch/Assets.xcassets").appendingPathComponent(name)
                let pngs = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".png") } ?? []
                XCTAssertFalse(pngs.isEmpty, name)
            }
        }
    }

    private func atlasImage(style: String) throws -> CGImage {
        let path = root.appendingPathComponent("TaptionPlanWidget/Assets.xcassets")
            .appendingPathComponent(TaptionHwarangPose.assetName(style: style) + ".imageset/atlas.png").path
        return try XCTUnwrap(UIImage(contentsOfFile: path)?.cgImage, path)
    }

    /// 칸을 같은 RGBA 판에 다시 그려 알파만 꺼낸다. PNG 색 공간 차이를 지운다.
    private func alpha(_ image: CGImage) -> [UInt8]? {
        let cell = TaptionHwarangPose.cellPixels
        var bytes = [UInt8](repeating: 0, count: cell.width * cell.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: cell.width, height: cell.height, bitsPerComponent: 8,
                bytesPerRow: cell.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: cell.width, height: cell.height))
            return true
        }
        guard drawn else { return nil }
        return stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
    }

    /// 불투명 영역 중 알파가 크게 다른 화소 비율.
    private func mismatch(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        let covered = zip(lhs, rhs).filter { $0 > 0 || $1 > 0 }
        guard !covered.isEmpty else { return 0 }
        return Double(covered.filter { abs(Int($0) - Int($1)) > 48 }.count) / Double(covered.count)
    }
}
