import SwiftUI
import UIKit

struct PhotoGalleryView: View {
    @Bindable var model: AppModel

    private var visibleSpan: TimeSpan {
        TimelineAxisGrid.span(
            for: model.selectedScale,
            containing: model.selectedDate
        )
    }

    private var clusters: [PhotoCluster] {
        PhotoClusterer.cluster(
            model.snapshot.photos.filter {
                visibleSpan.contains($0.capturedAt) &&
                !$0.isHiddenFromTimeline
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("현재 기간의 사진")
                    .font(.taption(size: 13, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Spacer()
                Text(selectedPeriodLabel)
                    .font(.taption(size: 11, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if clusters.isEmpty {
                ContentUnavailableView(
                    "표시할 사진이 없습니다",
                    systemImage: "photo"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 150), spacing: 12)
                        ],
                        spacing: 12
                    ) {
                        ForEach(clusters) { cluster in
                            Button {
                                model.selectedPhotoCluster = cluster
                            } label: {
                                PhotoGalleryClusterTile(
                                    model: model,
                                    cluster: cluster
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(Color.tpBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var selectedPeriodLabel: String {
        let calendar = Calendar.autoupdatingCurrent
        let formatter = Date.FormatStyle()
            .locale(Locale(identifier: "ko_KR"))
            .year(.defaultDigits)
            .month(.twoDigits)
            .day(.twoDigits)
        switch model.selectedScale {
        case .day:
            return visibleSpan.start.formatted(formatter)
        case .week:
            guard let end = calendar.date(
                byAdding: .day,
                value: 6,
                to: visibleSpan.start
            ) else { return visibleSpan.start.formatted(formatter) }
            return "\(visibleSpan.start.formatted(formatter)) ~ \(end.formatted(formatter))"
        case .month:
            return "\(calendar.component(.month, from: visibleSpan.start))월"
        case .year:
            return "\(calendar.component(.year, from: visibleSpan.start))년"
        }
    }
}

private struct PhotoGalleryClusterTile: View {
    @Bindable var model: AppModel
    let cluster: PhotoCluster

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                PhotoGalleryThumbnail(
                    model: model,
                    localIdentifier: cluster.representative.id
                )
                .frame(height: 150)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 16,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: 16,
                        style: .continuous
                    )
                    .stroke(Color.white, lineWidth: 1.8)
                }
                if cluster.additionalCount > 0 {
                    Text("+\(cluster.additionalCount)")
                        .font(.taption(size: 12, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(Color.tpPhotoDark)
                        )
                        .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(cluster.capturedAt.formatted(date: .omitted, time: .shortened))
                    .font(.taption(size: 12, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                    .lineLimit(1)
                Text("사진 \(cluster.photos.count)장")
                    .font(.taption(size: 11))
                    .foregroundStyle(Color.tpSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.white)
        .clipShape(
            RoundedRectangle(
                cornerRadius: 14,
                style: .continuous
            )
        )
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }
}

private struct PhotoGalleryThumbnail: View {
    @Bindable var model: AppModel
    let localIdentifier: String
    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if loadFailed {
                ZStack {
                    Color.tpPhoto.opacity(0.32)
                    Image(systemName: "photo.fill")
                        .font(.taption(size: 36, weight: .semibold))
                        .foregroundStyle(Color.tpPhotoDark)
                }
            } else {
                ZStack {
                    Color.tpPhoto.opacity(0.32)
                    ProgressView()
                        .controlSize(.small)
                        .tint(.tpPhotoDark)
                }
            }
        }
        .task(id: localIdentifier) {
            guard image == nil else { return }
            guard let data = try? await model.photoThumbnailData(
                localIdentifier: localIdentifier,
                size: CGSize(width: 420, height: 420)
            ) else {
                loadFailed = true
                return
            }
            image = UIImage(data: data)
            loadFailed = image == nil
        }
    }
}
