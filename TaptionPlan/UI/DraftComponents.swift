import SwiftUI

struct CatFaceView: View {
    let coat: CatCoat

    var body: some View {
        TaptionCatAnimationView(
            style: coat.rawValue,
            pose: TaptionCatAnimationEngine.pose(
                at: Date(timeIntervalSinceReferenceDate: 0),
                preferredAction: .sitting,
                reducesMotion: true
            ),
            reducesMotion: true
        )
        .frame(width: 52, height: 34)
        .accessibilityHidden(true)
    }
}

