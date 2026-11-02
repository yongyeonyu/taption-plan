import SwiftUI
import UIKit

struct PhotoClusterPage: View {
    @Bindable var model: AppModel
    let photo: PhotoMoment
    let index: Int
    let totalCount: Int
    @State private var image: UIImage?
    @State private var failedToLoad = false

    var body: some View {
        ZStack {
            Color.black

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("사진")
            } else if failedToLoad {
                VStack(spacing: TaptionSpacing.regular) {
                    Image(systemName: "photo")
                        .accessibilityHidden(true)
                        .font(.taption(size: 24, weight: .semibold))
                    Text("사진을 불러오지 못했습니다")
                        .font(.taption(size: 9, weight: .semibold))
                }
                .foregroundStyle(Color.white.opacity(0.72))
            } else {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "사진 \(index + 1), 전체 \(totalCount)장"
        )
        .accessibilityHint("좌우로 쓸어 다음 사진이나 이전 사진 보기")
        .task(id: photo.id) {
            guard image == nil else { return }
            guard let data = try? await model.photoThumbnailData(
                localIdentifier: photo.id,
                size: previewSize
            ) else {
                failedToLoad = true
                return
            }
            image = UIImage(data: data)
            failedToLoad = image == nil
        }
    }

    private var previewSize: CGSize {
        let width = max(1, photo.pixelWidth)
        let height = max(1, photo.pixelHeight)
        let longestSide = max(width, height)
        let scale = min(1, 1_600 / CGFloat(longestSide))
        return CGSize(
            width: CGFloat(width) * scale,
            height: CGFloat(height) * scale
        )
    }
}
