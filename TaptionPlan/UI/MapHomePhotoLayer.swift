import CoreLocation
import Photos
import SwiftUI
import UIKit

/// 같은 장소에서 찍은 사진 묶음. 지도에 썸네일과 개수로 보인다.
struct MapHomePhotoCluster: Identifiable, Equatable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    /// 촬영 시각 오름차순.
    let moments: [PhotoMoment]

    var count: Int { moments.count }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.moments.map(\.id) == rhs.moments.map(\.id)
    }
}

enum MapHomePhotoPolicy {
    /// 사이드바 선택 시각 주변으로 보는 범위(분).
    static let highlightWindowMinutes = 30
    /// 재생 중 사진이 지도에 머무는 재생 시간(분).
    static let playbackVisibleMinutes = 20.0

    /// 화면 배율(카메라 거리)에 따른 묶음 반경. 멀리서 볼수록 크게 묶는다.
    static func clusterRadiusMeters(cameraDistance: Double?) -> Double {
        guard let cameraDistance, cameraDistance.isFinite, cameraDistance > 0 else { return 80 }
        // 거리를 2배 단위 구간으로 나눠 확대·축소 중 묶음이 잦게 바뀌지 않게 한다.
        let bucket = pow(2, (log2(cameraDistance)).rounded())
        return min(max(bucket * 0.06, 25), 5_000)
    }

    /// 위치가 없는 사진(스크린샷 등)에 같은 시각 가장 가까운 내 위치 기록의 좌표를 넣는다.
    /// 기록이 `maximumGap` 안에 없으면 위치 없이 둔다. 사진 자체의 위치가 있으면 그대로 둔다.
    static func placingUnlocated(
        _ moments: [PhotoMoment],
        readings: [SensorReading],
        maximumGap: TimeInterval = 20 * 60
    ) -> [PhotoMoment] {
        guard moments.contains(where: { $0.location == nil }) else { return moments }
        let located = readings.filter { $0.point != nil }.sorted { $0.timestamp < $1.timestamp }
        guard !located.isEmpty else { return moments }
        func nearest(to date: Date) -> SensorReading? {
            var low = 0, high = located.count
            while low < high {
                let mid = (low + high) / 2
                if located[mid].timestamp < date { low = mid + 1 } else { high = mid }
            }
            let candidates = [low - 1, low].filter { located.indices.contains($0) }.map { located[$0] }
            return candidates.min {
                abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
            }
        }
        return moments.map { moment in
            guard moment.location == nil,
                  let reading = nearest(to: moment.capturedAt),
                  abs(reading.timestamp.timeIntervalSince(moment.capturedAt)) <= maximumGap,
                  let point = reading.point else { return moment }
            var placed = moment
            placed.location = point
            placed.isLocationEstimated = true
            return placed
        }
    }

    static func locatedMoments(_ moments: [PhotoMoment]) -> [PhotoMoment] {
        moments.filter { $0.location != nil && !$0.isHiddenFromTimeline }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    /// 시간순으로 훑으며 가장 가까운 기존 묶음(반경 이내)에 넣거나 새 묶음을 만든다.
    static func clusters(from moments: [PhotoMoment], radiusMeters: Double) -> [MapHomePhotoCluster] {
        struct Builder {
            var anchor: CLLocation
            var moments: [PhotoMoment]
        }
        var builders: [Builder] = []
        for moment in locatedMoments(moments) {
            guard let point = moment.location else { continue }
            let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
            var best: (index: Int, distance: Double)?
            for (index, builder) in builders.enumerated() {
                let distance = builder.anchor.distance(from: location)
                if distance <= radiusMeters, distance < (best?.distance ?? .infinity) {
                    best = (index, distance)
                }
            }
            if let best {
                builders[best.index].moments.append(moment)
            } else {
                builders.append(Builder(anchor: location, moments: [moment]))
            }
        }
        return builders.map {
            MapHomePhotoCluster(
                id: $0.moments[0].id,
                coordinate: $0.anchor.coordinate,
                moments: $0.moments
            )
        }
    }

    static func minuteOfDay(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Double {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(parts.hour ?? 0) * 60 + Double(parts.minute ?? 0) + Double(parts.second ?? 0) / 60
    }

    /// 사이드바 선택 시각 ±window 안에 찍은 사진이 있으면 강조한다.
    static func isHighlighted(
        _ cluster: MapHomePhotoCluster,
        selectedMinute: Double,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        cluster.moments.contains {
            abs(minuteOfDay($0.capturedAt, calendar: calendar) - selectedMinute) <= Double(highlightWindowMinutes)
        }
    }

    /// 재생 시각까지 지나온 사진 중 최근 `playbackVisibleMinutes` 안의 것만 순서대로 보인다.
    static func playbackVisibleMoments(
        in cluster: MapHomePhotoCluster,
        playbackMinute: Double,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [PhotoMoment] {
        cluster.moments.filter {
            let elapsed = playbackMinute - minuteOfDay($0.capturedAt, calendar: calendar)
            return elapsed >= 0 && elapsed <= playbackVisibleMinutes
        }
    }
}

private final class LockedRequestID: @unchecked Sendable {
    private let lock = NSLock()
    private var id: PHImageRequestID?
    private var isCancelled = false

    func set(_ newID: PHImageRequestID) {
        lock.lock()
        id = newID
        let cancelled = isCancelled
        lock.unlock()
        if cancelled { PHImageManager.default().cancelImageRequest(newID) }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let current = id
        lock.unlock()
        if let current { PHImageManager.default().cancelImageRequest(current) }
    }
}

@MainActor
final class MapHomePhotoImageLoader {
    static let shared = MapHomePhotoImageLoader()
    private let cache = NSCache<NSString, UIImage>()

    func image(localIdentifier: String, side: CGFloat) async -> UIImage? {
        let key = "\(localIdentifier)|\(Int(side))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            return nil
        }
        let scale = UIScreen.main.scale
        let size = CGSize(width: side * scale, height: side * scale)
        let requestID = LockedRequestID()
        let image: UIImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            var resumed = false
            requestID.set(PHImageManager.default().requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                guard !resumed else { return }
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                resumed = true
                continuation.resume(returning: image)
            })
            }
        } onCancel: {
            requestID.cancel()
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

struct MapHomePhotoThumbnail: View {
    let localIdentifier: String
    let side: CGFloat
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.tpSurface
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(Color.tpSecondary)
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .task(id: localIdentifier) {
            if image != nil { image = nil }
            image = await MapHomePhotoImageLoader.shared.image(localIdentifier: localIdentifier, side: side)
        }
    }
}

/// 지도에 놓이는 사진 묶음 핀: 썸네일 + 개수 배지. 선택 시각 주변 사진이면 테두리가 강조된다.
struct MapHomePhotoPin: View {
    let coverID: String
    let count: Int
    let isHighlighted: Bool

    var body: some View {
        MapHomePhotoThumbnail(localIdentifier: coverID, side: 46)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isHighlighted ? Color.tpAccent : Color.white, lineWidth: isHighlighted ? 3 : 2)
            }
            .overlay(alignment: .topTrailing) {
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tpAccent, in: Capsule())
                        .offset(x: 8, y: -8)
                }
            }
            .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("사진 \(count)장"))
            .accessibilityAddTraits(.isButton)
    }
}

/// 격자 앨범. 사진을 누르면 전체 화면으로 넘겨 본다.
struct MapHomePhotoAlbumSheet: View {
    let moments: [PhotoMoment]
    let language: MapHomeLanguage
    @State private var pagerIndex: Int?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 3)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(Array(moments.enumerated()), id: \.element.id) { index, moment in
                        Button { pagerIndex = index } label: {
                            MapHomePhotoThumbnail(localIdentifier: moment.id, side: 120)
                                .frame(minWidth: 0, maxWidth: .infinity)
                                .aspectRatio(1, contentMode: .fill)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(language.text("사진 \(moments.count)장", "\(moments.count) photos"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .fullScreenCover(isPresented: Binding(
            get: { pagerIndex != nil },
            set: { if !$0 { pagerIndex = nil } }
        )) {
            MapHomePhotoPager(moments: moments, startIndex: pagerIndex ?? 0, language: language)
        }
    }
}

struct MapHomePhotoPager: View {
    let moments: [PhotoMoment]
    @State var index: Int
    let language: MapHomeLanguage
    @Environment(\.dismiss) private var dismiss

    init(moments: [PhotoMoment], startIndex: Int, language: MapHomeLanguage) {
        self.moments = moments
        self._index = State(initialValue: startIndex)
        self.language = language
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(moments.enumerated()), id: \.element.id) { offset, moment in
                    VStack(spacing: 8) {
                        MapHomePhotoThumbnail(localIdentifier: moment.id, side: 380, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Text(moment.capturedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(30))))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(16)
            }
            .accessibilityLabel(language.text("닫기", "Close"))
        }
    }
}


struct MapHomePhotoAlbumSelection: Identifiable {
    let id: String
    let moments: [PhotoMoment]
}
