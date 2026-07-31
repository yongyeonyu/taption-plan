import SwiftUI
import UIKit

struct PhotoClusterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let cluster: PhotoCluster

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 9) {
                    if !contextLabels.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("이 시간의 맥락")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(Color.tpSecondary)
                            ChipFlowLayout(spacing: 5) {
                                ForEach(contextLabels, id: \.self) {
                                    Text($0)
                                        .font(
                                            .system(
                                                size: 9,
                                                weight: .semibold
                                            )
                                        )
                                        .foregroundStyle(Color.tpInk)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 5)
                                        .background(
                                            Color.white,
                                            in: Capsule()
                                        )
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

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 3),
                            GridItem(.flexible(), spacing: 3),
                            GridItem(.flexible(), spacing: 3),
                        ],
                        spacing: 3
                    ) {
                        ForEach(cluster.photos) { photo in
                            VStack(alignment: .leading, spacing: 3) {
                                PhotoClusterThumbnail(
                                    model: model,
                                    localIdentifier: photo.id
                                )
                                .aspectRatio(1, contentMode: .fill)
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: 9,
                                        style: .continuous
                                    )
                                )
                                Text(
                                    photo.capturedAt.formatted(
                                        date: .omitted,
                                        time: .shortened
                                    )
                                )
                                .font(
                                    .system(size: 7, weight: .semibold)
                                )
                                .foregroundStyle(Color.tpSecondary)
                                .padding(.horizontal, 2)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .background(Color.tpBackground)
            .navigationTitle(
                "\(cluster.capturedAt.formatted(date: .abbreviated, time: .omitted)) · 사진 \(cluster.photos.count)장"
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

private struct PhotoClusterThumbnail: View {
    @Bindable var model: AppModel
    let localIdentifier: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.tpPhoto.opacity(0.55)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.tpPhotoDark)
            }
        }
        .clipped()
        .task(id: localIdentifier) {
            guard image == nil else { return }
            guard let data = try? await model.photoThumbnailData(
                localIdentifier: localIdentifier,
                size: CGSize(width: 480, height: 480)
            ) else {
                return
            }
            image = UIImage(data: data)
        }
    }
}
