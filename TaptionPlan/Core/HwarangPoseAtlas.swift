import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 잠금화면·다이나믹 아일랜드에 쓰는 화랑이 자세. 앱의 장면을 털색별 그림으로 미리 뽑아 둔다.
enum TaptionHwarangPose: String, CaseIterable, Sendable {
    case deepSleep, remSleep, recovery, medication, hospital
    case restStarfish, restCroissant, restDonut, restLoaf, restBox
    case nap, meditation, salon, cooking, groceries, laundry, dishes, coffee, housework, shower
    case meeting, friends, date, family, phoneCall, bookReading, game, music, video, petCare
    case workDesk, studyDesk, laptopWalk

    private static let titles: [String: TaptionHwarangPose] = [
        "깊은 수면": .deepSleep, "rem 수면": .remSleep, "회복": .recovery, "투약": .medication, "병원": .hospital,
        "집에서 휴식": .restBox, "낮잠": .nap, "명상": .meditation, "미용실": .salon,
        "요리": .cooking, "장보기": .groceries, "빨래": .laundry, "설거지": .dishes, "커피·티타임": .coffee, "멍때리기": .restBox, "집안일": .housework, "샤워": .shower,
        "회의": .meeting, "친구 만남": .friends, "데이트": .date, "가족": .family, "통화": .phoneCall,
        "독서": .bookReading, "게임": .game, "음악": .music, "영상 보기": .video, "반려동물 돌보기": .petCare
    ]

    /// 제목이 분명한 상세활동만 고른다. 그 밖에는 기존 동작 그림을 쓴다.
    static func resolve(categoryID: String, title: String) -> TaptionHwarangPose? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let pose = titles[name] { return pose }
        let root = categoryID.split(separator: ".").first.map(String.init) ?? categoryID
        // 업무·공부는 예전 꾹꾹이 그림이 자는 것처럼 보여 노트북·책 그림을 쓴다(WCH1105A03).
        if name != "휴식" {
            switch root {
            case "work": return name == "걷기" ? .laptopWalk : .workDesk
            case "study": return .studyDesk
            default: return nil
            }
        }
        switch root {
        case "work": return .restCroissant
        case "study": return .restDonut
        case "hobby": return .restLoaf
        default: return .restStarfish
        }
    }

    static let frameCount = 4
    static let cellPixels = (width: 104, height: 64)

    var row: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    static func assetName(style: String) -> String {
        "TaptionPoseAtlas" + style.prefix(1).uppercased() + style.dropFirst()
    }
}

#if canImport(UIKit)
extension TaptionCatAtlasBitmap {
    static func poseImage(style: String, pose: TaptionHwarangPose, frame: Int) -> UIImage? {
        guard let atlas = UIImage(named: TaptionHwarangPose.assetName(style: style), in: TaptionCatAtlasBundle.current, with: nil)?.cgImage else { return nil }
        let cell = TaptionHwarangPose.cellPixels
        let column = ((frame % TaptionHwarangPose.frameCount) + TaptionHwarangPose.frameCount) % TaptionHwarangPose.frameCount
        return atlas.cropping(to: CGRect(x: column * cell.width, y: pose.row * cell.height, width: cell.width, height: cell.height))
            .map { UIImage(cgImage: $0, scale: 2, orientation: .up) }
    }
}
#endif
