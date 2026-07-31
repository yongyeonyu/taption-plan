import SwiftUI
import UIKit

struct PhotoClusterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let cluster: PhotoCluster
    @State private var selectedIndex = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 9) {
                if photos.isEmpty {
                    ContentUnavailableView(
                        "표시할 사진이 없습니다",
                        systemImage: "photo"
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    TabView(selection: $selectedIndex) {
                        ForEach(
                            Array(photos.enumerated()),
                            id: \.element.id
                        ) { index, photo in
                            PhotoClusterPage(
                                model: model,
                                photo: photo,
                                index: index,
                                totalCount: photos.count
                            )
                            .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        Color.black,
                        in: RoundedRectangle(
                            cornerRadius: 14,
                            style: .continuous
                        )
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 14,
                            style: .continuous
                        )
                    )

                    HStack(spacing: 8) {
                        Text(selectedPhotoTime)
                        Spacer(minLength: 8)
                        Text("\(selectedIndex + 1) / \(photos.count)")
                    }
                    .font(.taption(size: 8, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.horizontal, 2)

                    if !contextLabels.isEmpty {
                        contextStrip
                    }
                }
            }
            .padding(10)
            .background(Color.tpBackground)
            .navigationTitle(
                "\(cluster.capturedAt.formatted(date: .abbreviated, time: .omitted)) · 사진 \(photos.count)장"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var photos: [PhotoMoment] {
        cluster.photos.sorted { $0.capturedAt < $1.capturedAt }
    }

    private var selectedPhotoTime: String {
        guard photos.indices.contains(selectedIndex) else { return "" }
        return photos[selectedIndex].capturedAt.formatted(
            date: .omitted,
            time: .shortened
        )
    }

    private var contextStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("이 시간의 맥락")
                .font(.taption(size: 10, weight: .black))
                .foregroundStyle(Color.tpSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(contextLabels, id: \.self) {
                        Text($0)
                            .font(
                                .taption(
                                    size: 9,
                                    weight: .semibold
                                )
                            )
                            .foregroundStyle(Color.tpInk)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(Color.white, in: Capsule())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            Color.tpPhoto.opacity(0.42),
            in: RoundedRectangle(
                cornerRadius: 13,
                style: .continuous
            )
        )
    }

    private var contextLabels: [String] {
        guard let first = cluster.photos.map(\.capturedAt).min(),
              let last = cluster.photos.map(\.capturedAt).max() else {
            return []
        }
        let contextSpan = TimeSpan(
            start: first.addingTimeInterval(-30 * 60),
            end: last.addingTimeInterval(30 * 60)
        )
        let plans = model.snapshot.plans
            .filter { $0.span.intersection(with: contextSpan) != nil }
            .map { "계획 · \($0.title)" }
        let places = model.snapshot.places
            .filter { $0.span.intersection(with: contextSpan) != nil }
            .map { place in
                if let floor = place.floor {
                    return "위치 · \(place.displayName) \(floor)층"
                }
                return "위치 · \(place.displayName)"
            }
        var seen = Set<String>()
        return (plans + places).filter {
            seen.insert($0).inserted
        }
    }
}

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
            } else if failedToLoad {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
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
