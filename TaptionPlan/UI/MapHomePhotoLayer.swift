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
    /// 지금 시각에 가장 가까이 찍은 사진. 링이 여기서 시작한다.
    static func nearest(_ photos: [PhotoMoment], toMinute minute: Double) -> PhotoMoment? {
        photos.min { abs(minuteOfDay($0.capturedAt) - minute) < abs(minuteOfDay($1.capturedAt) - minute) }
    }

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
/// 사진 핀을 화랑이·카운터 창·등록 지점·메모에 겹치지 않는 가까운 자리로 옮긴다. 핀은 아래쪽이 기준점이다.
/// 사진 위치는 정확하지 않아도 된다(대표 요청).
enum MapHomePhotoPlacement {
    private static let pinSide: CGFloat = 54
    private static let directions: [CGPoint] = [
        CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: -1), CGPoint(x: -1, y: -1),
        CGPoint(x: 1, y: -1), CGPoint(x: -1, y: 1), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
    ]

    static func obstacle(center: CGPoint, side: CGFloat) -> CGRect {
        CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    private static func rect(at point: CGPoint) -> CGRect {
        CGRect(x: point.x - pinSide / 2, y: point.y - pinSide, width: pinSide, height: pinSide)
    }

    static func point(for pin: CGPoint, avoiding obstacles: [CGRect]) -> CGPoint {
        func isClear(_ point: CGPoint) -> Bool { !obstacles.contains { $0.intersects(rect(at: point)) } }
        if isClear(pin) { return pin }
        for distance in stride(from: CGFloat(30), through: 300, by: 30) {
            for direction in directions {
                let candidate = CGPoint(x: pin.x + direction.x * distance, y: pin.y + direction.y * distance)
                if isClear(candidate) { return candidate }
            }
        }
        return pin
    }
}

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
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
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

/// 전체 화면 사진. 정사각 칸에 가두지 않고 화면에 맞춘다.
struct MapHomePhotoFullImage: View {
    let localIdentifier: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: localIdentifier) {
            image = await MapHomePhotoImageLoader.shared.image(localIdentifier: localIdentifier, side: 1_000)
        }
    }
}

struct MapHomePhotoPager: View {
    let moments: [PhotoMoment]
    @State var index: Int
    let language: MapHomeLanguage
    @Environment(\.dismiss) private var dismiss
    @State private var pullDown: CGFloat = 0

    /// 이만큼 아래로 쓸면 닫는다.
    nonisolated static func closesOnPull(translation: CGSize, predictedHeight: CGFloat) -> Bool {
        translation.height > abs(translation.width) && max(translation.height, predictedHeight) > 120
    }

    init(moments: [PhotoMoment], startIndex: Int, language: MapHomeLanguage) {
        self.moments = moments
        self._index = State(initialValue: startIndex)
        self.language = language
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(1 - min(0.6, pullDown / 500)).ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(moments.enumerated()), id: \.element.id) { offset, moment in
                    VStack(spacing: 8) {
                        MapHomePhotoFullImage(localIdentifier: moment.id)
                        Text(moment.capturedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .offset(y: pullDown)
            .simultaneousGesture(
                DragGesture(minimumDistance: 16)
                    .onChanged { value in
                        // 옆으로 넘기는 동안에는 따라 내려가지 않는다.
                        let next = value.translation.height > abs(value.translation.width) ? value.translation.height : 0
                        if next != pullDown { pullDown = next }
                    }
                    .onEnded { value in
                        if Self.closesOnPull(translation: value.translation, predictedHeight: value.predictedEndTranslation.height) {
                            dismiss()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { pullDown = 0 }
                        }
                    }
            )
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


/// 지도에서 누른 사진. 그날 사진 전체를 이 사진부터 넘겨 본다.
struct MapHomePhotoBrowserSelection: Equatable {
    let startID: String?
}

/// 지도 사진 탐색(PHO1105A01). 재생과 같은 반달에서 좌우로 밀어 넘기고, 가운데를 누르면 크게 본다.
struct MapHomePhotoArcBrowser: View {
    let moments: [PhotoMoment]
    let language: MapHomeLanguage
    let trailing: CGFloat
    /// 하단 링: 지도를 가리지 않고 계속 떠 있으며, 넘길 때마다 알린다.
    let isRing: Bool
    let onPhotoChange: ((PhotoMoment) -> Void)?
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index: Int
    @State private var dragStartIndex: Int?
    @State private var pagerIndex: Int?

    /// 손가락이 이만큼 움직이면 사진 한 장을 넘긴다.
    private static let pointsPerPhoto: CGFloat = 36
    private static let swipeDepth: CGFloat = MapHomePlaybackPhotoStrip.arcDrop + 46

    init(
        moments: [PhotoMoment],
        startID: String?,
        language: MapHomeLanguage,
        trailing: CGFloat,
        isRing: Bool = false,
        onPhotoChange: ((PhotoMoment) -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.isRing = isRing
        self.onPhotoChange = onPhotoChange
        self.moments = moments
        self.language = language
        self.trailing = trailing
        self.onClose = onClose
        _index = State(initialValue: moments.firstIndex { $0.id == startID } ?? 0)
    }

    /// 왼쪽으로 밀면 다음 사진이다.
    nonisolated static func index(start: Int, translation: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let moved = Int((-translation / pointsPerPhoto).rounded())
        return min(count - 1, max(0, start + moved))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if !isRing {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                    .accessibilityLabel(language.text("닫기", "Close"))
                    .accessibilityAddTraits(.isButton)
            }
            VStack(spacing: 10) {
                caption
                arc
            }
            .playbackBrowserPlacement(trailing: trailing)
        }
        .sensoryFeedback(.selection, trigger: index)
        .onChange(of: index) { _, value in
            guard moments.indices.contains(value) else { return }
            onPhotoChange?(moments[value])
        }
        .fullScreenCover(isPresented: Binding(
            get: { pagerIndex != nil },
            set: { if !$0 { pagerIndex = nil } }
        )) {
            MapHomePhotoPager(moments: moments, startIndex: pagerIndex ?? 0, language: language)
        }
    }

    private var caption: some View {
        Text("\(moments[index].capturedAt.formatted(date: .omitted, time: .shortened)) · \(index + 1)/\(moments.count)")
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold))
            .foregroundStyle(Color.tpInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.tpSurface, in: Capsule())
            .accessibilityHidden(true)
    }

    private var arc: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                ForEach(MapHomePlaybackPhotoStrip.visibleIndices(current: index, count: moments.count), id: \.self) { photoIndex in
                    MapHomePhotoArcSlot(
                        id: moments[photoIndex].id,
                        distance: photoIndex - index,
                        countOnSide: photoIndex > index
                            ? min(MapHomePlaybackPhotoStrip.slotsPerSide, moments.count - 1 - index)
                            : min(MapHomePlaybackPhotoStrip.slotsPerSide, index),
                        side: 46,
                        width: proxy.size.width,
                        isEnlarged: true
                    )
                    .onTapGesture {
                        if photoIndex == index { pagerIndex = index } else { index = photoIndex }
                    }
                }
            }
            .frame(width: proxy.size.width, height: MapHomePlaybackPhotoStrip.centerSide, alignment: .bottom)
        }
        .frame(height: MapHomePlaybackPhotoStrip.centerSide)
        // 호가 아래로 내려간 끝까지 밀 수 있게 잡는 자리를 넓힌다. 놓이는 자리는 그대로다.
        .padding(.bottom, Self.swipeDepth)
        .contentShape(Rectangle())
        .simultaneousGesture(swipe)
        .padding(.bottom, -Self.swipeDepth)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.8), value: index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(language.text(
            "사진 \(index + 1)/\(moments.count), \(moments[index].capturedAt.formatted(date: .omitted, time: .shortened))",
            "Photo \(index + 1) of \(moments.count), \(moments[index].capturedAt.formatted(date: .omitted, time: .shortened))"
        ))
        .accessibilityHint(language.text("위아래로 쓸어 넘기고, 두 번 눌러 크게 봅니다", "Swipe up or down to change, double-tap to enlarge"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: index = min(moments.count - 1, index + 1)
            case .decrement: index = max(0, index - 1)
            @unknown default: break
            }
        }
        .accessibilityAction { pagerIndex = index }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let start = dragStartIndex ?? index
                if dragStartIndex == nil { dragStartIndex = start }
                let next = Self.index(start: start, translation: value.translation.width, count: moments.count)
                if next != index { index = next }
            }
            .onEnded { value in
                // 빠르게 튕기면 관성만큼 더 넘어간다.
                let next = Self.index(start: dragStartIndex ?? index, translation: value.predictedEndTranslation.width, count: moments.count)
                dragStartIndex = nil
                if next != index { index = next }
            }
    }
}

private extension View {
    func playbackBrowserPlacement(trailing: CGFloat) -> some View {
        padding(.leading, 12).padding(.trailing, trailing).padding(.bottom, MapHomePlaybackPhotoStrip.bottomInset)
    }
}

/// 반달 위 사진 한 칸. 재생과 지도 탐색이 같은 모양을 쓴다.
struct MapHomePhotoArcSlot: View {
    let id: String
    let distance: Int
    let countOnSide: Int
    let side: CGFloat
    let width: CGFloat
    let isEnlarged: Bool

    var body: some View {
        let isCenter = distance == 0 && isEnlarged
        let place = MapHomePlaybackPhotoStrip.arcPlacement(distance: distance, countOnSide: countOnSide, side: side, width: width, isEnlarged: isEnlarged)
        MapHomePhotoThumbnail(localIdentifier: id, side: MapHomePlaybackPhotoStrip.centerSide)
            // 지금 사진만 밝게 두고 나머지는 30% 어둡게 한다.
            .overlay(Color.black.opacity(distance == 0 ? 0 : 0.3))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white, lineWidth: isCenter ? 3 : 4))
            .scaleEffect(isCenter ? 1 : side / MapHomePlaybackPhotoStrip.centerSide, anchor: .bottom)
            .rotationEffect(.degrees(place.degrees), anchor: .bottom)
            .shadow(color: .black.opacity(isCenter ? 0.3 : 0.16), radius: isCenter ? 7 : 3, y: 2)
            // 가운데에 가까운 사진이 위에 온다.
            .zIndex(isCenter ? 100 : Double(MapHomePlaybackPhotoStrip.slotsPerSide - abs(distance)))
            .offset(x: place.x, y: place.y)
            .transition(.opacity)
    }
}

/// 재생 중 사진 미리보기. 화랑이를 가리지 않게 하단에 7칸을 두고, 지금 사진을 가운데에 크게 보여 준다.
struct MapHomePlaybackPhotoStrip: View {
    struct Photo: Equatable {
        let minute: Double
        let id: String
    }

    let minute: Double
    let photos: [Photo]

    /// 많으면 호 위에서 겹쳐 쌓인다(대표 지시).
    static let slotsPerSide = 12
    static let centerSide: CGFloat = 168
    static let bottomInset: CGFloat = 104
    /// 새 사진이 크게 보이는 시간(대표 지시). 지나면 다른 칸과 같은 크기로 돌아간다.
    static let enlargedSeconds: UInt64 = 3
    private static let gap: CGFloat = 5
    private static let maxArcDegrees: CGFloat = 85
    /// 호가 내려가는 깊이. 아래 단추 줄에 닿기 전까지다.
    static let arcDrop: CGFloat = bottomInset - 16

    /// 지금까지 지나간 마지막 사진. 첫 사진 전이면 nil이고, 되감으면 그 자리로 돌아간다.
    nonisolated static func currentIndex(minute: Double, photos: [Photo]) -> Int? {
        photos.lastIndex { $0.minute <= minute }
    }

    /// 보여 줄 사진 번호. 가운데 양옆으로 최대 `slotsPerSide`칸씩이다.
    nonisolated static func visibleIndices(current: Int?, count: Int) -> [Int] {
        let center = current ?? -1
        let lower = max(0, center - slotsPerSide), upper = min(count - 1, center + slotsPerSide)
        return lower <= upper ? Array(lower...upper) : []
    }

    static func photos(from moments: [PhotoMoment], day: Date) -> [Photo] {
        let start = Calendar.autoupdatingCurrent.startOfDay(for: day)
        return moments
            .map { Photo(minute: $0.capturedAt.timeIntervalSince(start) / 60, id: $0.id) }
            .sorted { $0.minute < $1.minute }
    }

    func playbackPlacement(trailing: CGFloat) -> some View {
        padding(.leading, 12).padding(.trailing, trailing).padding(.bottom, Self.bottomInset)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isEnlarged = false

    var body: some View {
        let current = Self.currentIndex(minute: minute, photos: photos)
        GeometryReader { proxy in
            let side: CGFloat = 46
            ZStack(alignment: .bottom) {
                ForEach(Self.visibleIndices(current: current, count: photos.count), id: \.self) { index in
                    slot(index: index, center: current ?? -1, side: side, width: proxy.size.width)
                }
            }
            .frame(width: proxy.size.width, height: Self.centerSide, alignment: .bottom)
        }
        .frame(height: Self.centerSide)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.72), value: current)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.72), value: isEnlarged)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: current) {
            guard current != nil else { return isEnlarged = false }
            isEnlarged = true
            try? await Task.sleep(for: .seconds(Self.enlargedSeconds))
            if !Task.isCancelled { isEnlarged = false }
        }
    }

    /// 호 위의 자리. 가운데에서 멀수록 아래로 내려가는 반원이고, 칸이 호에 다 안 들어가면 간격을 줄여 겹친다.
    nonisolated static func arcPlacement(
        distance: Int, countOnSide: Int, side: CGFloat, width: CGFloat, isEnlarged: Bool
    ) -> (x: CGFloat, y: CGFloat, degrees: Double) {
        guard distance != 0 else { return (0, 0, 0) }
        let radius = max(side, width / 2 - side / 2 - 8)
        let clearance = (isEnlarged ? centerSide / 2 + side / 2 : side) + gap
        let first = asin(min(1, clearance / radius))
        let last = max(first, CGFloat.pi * maxArcDegrees / 180)
        let natural = (side + gap) / radius
        let spacing = countOnSide > 1 ? min(natural, (last - first) / CGFloat(countOnSide - 1)) : natural
        let angle = first + CGFloat(abs(distance) - 1) * spacing
        let direction: CGFloat = distance > 0 ? 1 : -1
        return (
            direction * radius * sin(angle),
            arcDrop * (1 - cos(angle)),
            Double(direction * angle) * 180 / .pi * 0.35
        )
    }

    private func slot(index: Int, center: Int, side: CGFloat, width: CGFloat) -> some View {
        MapHomePhotoArcSlot(
            id: photos[index].id,
            distance: index - center,
            countOnSide: index > center
                ? min(Self.slotsPerSide, photos.count - 1 - center)
                : min(Self.slotsPerSide, center),
            side: side,
            width: width,
            isEnlarged: isEnlarged
        )
    }
}

#if DEBUG
/// 화면 확인용. `-photoStripPreview` 실행 인자로만 뜬다. 분이 지나며 가운데 사진이 넘어간다.
struct MapHomePhotoStripPreviewHost: View {
    @State private var minute: Double = 0
    private let photos = (0..<20).map { MapHomePlaybackPhotoStrip.Photo(minute: Double($0) * 10, id: "preview-\($0)") }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.tpBackground.ignoresSafeArea()
            MapHomePlaybackPhotoStrip(minute: minute, photos: photos)
                .playbackPlacement(trailing: 60)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                minute = minute >= 190 ? 0 : minute + 10
            }
        }
    }
}

/// 화면 확인용. `-photoBrowserPreview` 실행 인자로만 뜬다.
struct MapHomePhotoBrowserPreviewHost: View {
    private let moments = (0..<20).map {
        PhotoMoment(id: "preview-\($0)", capturedAt: Date(timeIntervalSinceNow: Double($0) * 600), pixelWidth: 100, pixelHeight: 100, isFavorite: false, isHiddenFromTimeline: false, location: nil, linkedPlanID: nil)
    }

    var body: some View {
        ZStack {
            Color.tpBackground.ignoresSafeArea()
            MapHomePhotoArcBrowser(moments: moments, startID: "preview-5", language: .korean, trailing: 60) {}
        }
    }
}
#endif

/// 재생 중 지나간 사진과 메모를 잠깐 띄운다(PLY1104A02). 사진은 지도 아이콘의 3배로 떴다가 줄지 않고 희미해지고, 메모는 한 글자씩 찍힌다.
struct MapHomePlaybackMomentsOverlay: View {
    enum Moment: Equatable {
        case memo(text: String)
    }

    let minute: Double
    let events: [(minute: Double, moment: Moment)]
    var topInset: CGFloat = 8
    /// 왼쪽 여백부터 시간 막대 앞까지 채운다.
    var trailingInset: CGFloat = 16

    private struct Shown: Identifiable {
        let id = UUID()
        let text: String
    }

    @State private var queue: [Moment] = []
    @State private var shown: Shown?
    @State private var lastMinute: Double?
    @State private var lastShownAt = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 메모 하나가 떠 있는 시간(대표 지시).
    static let lifetime: TimeInterval = 3
    /// 여러 개가 몰려도 읽을 수 있게 다음 메모가 덮기까지 두는 최소 간격.
    static let minimumOverwriteGap: TimeInterval = 0.7

    /// 지난 분에서 이번 분 사이에 지나간 것을 순서대로. 되감기면 아무것도 띄우지 않는다.
    nonisolated static func passed<T>(_ events: [(minute: Double, moment: T)], from previous: Double?, to minute: Double) -> [T] {
        guard let previous, minute > previous else { return [] }
        return events.filter { $0.minute > previous && $0.minute <= minute }.map(\.moment)
    }

    var body: some View {
        VStack {
            if let shown {
                Text(shown.text)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                    .lineLimit(3)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                    .id(shown.id)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, topInset)
        .padding(.leading, 12)
        .padding(.trailing, trailingInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: shown?.id)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: minute) { old, new in
            queue += Self.passed(events, from: lastMinute ?? old, to: new)
            lastMinute = new
            advance(now: .now)
        }
    }

    private func advance(now: Date) {
        if !queue.isEmpty, now.timeIntervalSince(lastShownAt) >= Self.minimumOverwriteGap {
            if case .memo(let text) = queue.removeFirst() { shown = Shown(text: text) }
            lastShownAt = now
        } else if shown != nil, now.timeIntervalSince(lastShownAt) >= Self.lifetime {
            shown = nil
        }
    }

    static func events(memos: [ActionMemo], day: Date) -> [(minute: Double, moment: Moment)] {
        let start = Calendar.autoupdatingCurrent.startOfDay(for: day)
        return memos
            .map { (minute: $0.occurredAt.timeIntervalSince(start) / 60, moment: Moment.memo(text: $0.text)) }
            .sorted { $0.minute < $1.minute }
    }
}
