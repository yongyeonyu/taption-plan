import SwiftUI
import TaptionPlanCore

/// 잠금화면·다이나믹 아일랜드의 화랑이. 앱과 같은 고양이 아틀라스(`TaptionCatAtlasBitmap`)에서 한 프레임을 잘라 그린다.
struct TaptionLiveActivityCat: View {
    let categoryID: String
    let title: String
    var style: String = "white"
    var frame: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        let action = TaptionLiveActivityCatPolicy.action(categoryID: categoryID, title: title)
        let shownFrame = reduceMotion || dimmed ? 0 : frame
        let posed = TaptionHwarangPose.resolve(categoryID: categoryID, title: title)
            .flatMap { TaptionCatAtlasBitmap.poseImage(style: style, pose: $0, frame: shownFrame) }
        Group {
            if let bitmap = posed ?? TaptionCatAtlasBitmap.image(style: style, action: action, frame: shownFrame) {
                Image(uiImage: bitmap)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "cat.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if categoryID == "work" || categoryID == "study" {
                Image(systemName: categoryID == "work" ? "desktopcomputer" : "book.closed.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityLabel("\(style == "calico" ? "춘향이" : style == "mackerel" ? "윤복이" : "화랑이") \(title)")
    }
}
