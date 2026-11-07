import Foundation
import Photos
import TaptionPlanCore

// MARK: - Photos

enum PhotoServiceError: Error {
    case imageUnavailable
    case requestCancelled
}

final class ApplePhotoLibraryService: @unchecked Sendable {
    private let imageManager: PHImageManager

    init(imageManager: PHImageManager = .default()) {
        self.imageManager = imageManager
    }

    func permissionState() -> PermissionState {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        case .limited:
            return .limited
        case .authorized:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func requestAccess() async -> PermissionState {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        case .limited:
            return .limited
        case .authorized:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    /// 기간 안 사진 수. 격리되지 않은 async라 메인 스레드 밖에서 읽는다(하루 카드 고르기 값).
    func momentCount(in span: TimeSpan) async -> Int {
        moments(in: span).count
    }

    func moments(in span: TimeSpan) -> [PhotoMoment] {
        // 권한이 정해지기 전의 조회는 시스템 팝업을 띄운다.
        guard permissionState().isGranted else { return [] }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            span.start as NSDate,
            span.end as NSDate
        )
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: true)
        ]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var moments: [PhotoMoment] = []
        result.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate else { return }
            let point = asset.location.map {
                GeoPoint(
                    latitude: $0.coordinate.latitude,
                    longitude: $0.coordinate.longitude,
                    altitude: $0.altitude,
                    horizontalAccuracy: $0.horizontalAccuracy,
                    verticalAccuracy: $0.verticalAccuracy
                )
            }
            moments.append(
                PhotoMoment(
                    id: asset.localIdentifier,
                    capturedAt: date,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    isFavorite: asset.isFavorite,
                    isHiddenFromTimeline: asset.isHidden,
                    location: point,
                    linkedPlanID: nil,
                    linkedPlaceID: nil,
                    isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot) ? true : nil
                )
            )
        }
        return moments
    }

    func thumbnailJPEG(
        localIdentifier: String,
        size: CGSize,
        quality: CGFloat = 0.8
    ) async throws -> Data {
        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        )
        guard let asset = assets.firstObject else {
            throw PhotoServiceError.imageUnavailable
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        return try await withCheckedThrowingContinuation { continuation in
            imageManager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: PhotoServiceError.requestCancelled)
                    return
                }
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                    return
                }
                guard let data = image?.jpegData(compressionQuality: quality) else {
                    continuation.resume(throwing: PhotoServiceError.imageUnavailable)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }
}
