import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

/// body마다 여러 번 읽히는 사진 묶음을 (사진 목록, 반경)이 같으면 재사용한다.
@MainActor
final class MapHomePhotoClusterCache {
    private var key: Int?
    private var value: [MapHomePhotoCluster] = []

    func clusters(for moments: [PhotoMoment], radiusMeters: Double) -> [MapHomePhotoCluster] {
        var hasher = Hasher()
        hasher.combine(radiusMeters)
        for moment in moments {
            hasher.combine(moment.id)
            hasher.combine(moment.location?.latitude)
            hasher.combine(moment.location?.longitude)
        }
        let next = hasher.finalize()
        if key == next { return value }
        value = MapHomePhotoPolicy.clusters(from: moments, radiusMeters: radiusMeters)
        key = next
        return value
    }
}

enum MapHomePlacePinLayout {
    /// 집 마커 아바타의 지름. 지도 좌표에는 이 원의 중심이 놓인다.
    static let avatarSize: CGFloat = 78
    /// 아바타 뒤로 번지는 발광의 지름. 레이아웃에는 영향을 주지 않는다.
    static let glowSize: CGFloat = 140
    /// 아바타 안쪽에 넣는 레벨 아트의 크기. 원 테두리에 붙지 않게 조금 줄인다.
    static let artworkSize: CGFloat = 56
    /// 집 아이콘 아래 레벨 라벨 높이.
    static let levelLabelHeight: CGFloat = 22
    /// 아바타와 레벨 라벨 사이 간격.
    static let levelLabelGap: CGFloat = 5
    /// 날씨 배지를 아바타 위쪽에 걸치는 거리(음수 = 위).
    static let weatherBadgeLift: CGFloat = -10
    /// 아바타 중심을 좌표에 맞추기 위해 아래 라벨 블록 높이의 절반만큼 내린다.
    static let avatarCenterCompensation: CGFloat = (levelLabelGap + levelLabelHeight) / 2
    /// 연봉 카운터를 집 핀 중심에서 띄우는 거리(음수 = 위). 아바타 위 배지 줄보다 위에 둔다.
    static let salaryOffsetFromPinCenter: CGFloat = -62
    /// Apple 지도 호스팅 뷰의 집 핀 크기. 발광(140)보다 사방 10pt 넉넉히 잡아
    /// 지도가 상자 경계에서 잘라도 보이는 부분이 잘리지 않게 한다.
    static let appleHomeHostWidth: CGFloat = 160
    static let appleHomeHostHeight: CGFloat = 160
    /// 장착한 장식 스티커. 원 안 10pt로는 아트에 묻혀 읽히지 않아 원 밖으로 내보내고 키운다.
    static let accessoryStickerSize: CGFloat = 15
    static let accessoryStickerOffset: CGFloat = 10
}

enum MapHomePlaceAnnotationLayout {
    static let vectorAnchor = UnitPoint.center
    static let appleCenterOffset = CGPoint.zero
}

/// 일정 메모 미리보기: 사이드바 시각이 메모 시각의 앞뒤 30분 안에 오면 보여 준다(대표 선택).
enum MapHomeMemoPreviewPolicy {
    static let windowSeconds: TimeInterval = 30 * 60

    /// 선택한 날짜의 일정 메모 중 `now` 앞뒤 30분 안에서 가장 가까운 것(닫은 것은 제외). 없으면 nil.
    static func nearest(
        in stickers: [MapSticker],
        at now: Date,
        selectedDate: Date,
        dismissed: Set<UUID> = [],
        calendar: Calendar = .autoupdatingCurrent
    ) -> MapSticker? {
        stickers
            .filter {
                $0.placement == .schedule
                    && !dismissed.contains($0.id)
                    && calendar.isDate($0.occurredAt, inSameDayAs: selectedDate)
                    && abs($0.occurredAt.timeIntervalSince(now)) <= windowSeconds
            }
            .min { abs($0.occurredAt.timeIntervalSince(now)) < abs($1.occurredAt.timeIntervalSince(now)) }
    }
}

enum MapHomeStickmanAnnotationLayout {
    static let centerOffset = CGPoint(x: 0, y: -18)
}

enum MapHomePresencePolicy {
    static func isAtHome(
        current: CLLocationCoordinate2D,
        home: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance
    ) -> Bool {
        guard valid(current), valid(home), radiusMeters.isFinite,
              radiusMeters >= 0 else { return false }
        return CLLocation(latitude: current.latitude, longitude: current.longitude)
            .distance(from: CLLocation(latitude: home.latitude, longitude: home.longitude))
            <= radiusMeters
    }

    private static func valid(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude.isFinite
            && coordinate.longitude.isFinite
            && (-90...90).contains(coordinate.latitude)
            && (-180...180).contains(coordinate.longitude)
    }
}

/// 발바닥 색: 느리면 빨강, 중간 속도는 초록, 빠르면 파랑(시속 150km에서 최대)으로 같은 비율로 나눈다. 속도를 모르는 미확인은 회색.
enum MapHomePawprintSpeedColor {
    static let maximumMetersPerSecond = 150.0 / 3.6

    static func ratio(forMetersPerSecond speed: Double?) -> Double? {
        guard let speed, speed.isFinite, speed >= 0 else { return nil }
        return min(1, speed / maximumMetersPerSecond)
    }

    static func color(forMetersPerSecond speed: Double?) -> Color {
        guard let ratio = ratio(forMetersPerSecond: speed) else {
            return Color.gray.opacity(0.68)
        }
        // 색상환 빨강(0) → 초록(1/3) → 파랑(2/3)을 속도 비율 0~1에 고르게 대응시킨다.
        return Color(hue: (2.0 / 3.0) * ratio, saturation: 0.85, brightness: 0.82)
            .opacity(0.9)
    }

    /// 발자국 색 속도: 해당 점 앞뒤 `halfWindow`초 구간의 이동거리/시간. 인접 두 점의 순간 속도는
    /// GPS 잡음으로 튀고, 재생으로 발자국이 다시 뽑힐 때마다 색이 바뀌므로 시간 창으로 고정한다.
    static let windowSeconds: TimeInterval = 30

    static func windowedSpeed(
        coordinates: [CLLocationCoordinate2D],
        timestamps: [Date],
        index: Int,
        halfWindow: TimeInterval = windowSeconds
    ) -> Double? {
        guard coordinates.count == timestamps.count, coordinates.indices.contains(index),
              halfWindow > 0 else { return nil }
        let center = timestamps[index]
        var low = index
        while low > 0, center.timeIntervalSince(timestamps[low - 1]) <= halfWindow { low -= 1 }
        var high = index
        while high < coordinates.count - 1, timestamps[high + 1].timeIntervalSince(center) <= halfWindow {
            high += 1
        }
        guard high > low else { return nil }
        let seconds = timestamps[high].timeIntervalSince(timestamps[low])
        guard seconds > 0 else { return nil }
        var meters = 0.0
        for k in low..<high {
            meters += CLLocation(latitude: coordinates[k].latitude, longitude: coordinates[k].longitude)
                .distance(from: CLLocation(latitude: coordinates[k + 1].latitude, longitude: coordinates[k + 1].longitude))
        }
        return meters / seconds
    }

    static func speed(
        from first: CLLocationCoordinate2D,
        at firstDate: Date?,
        to second: CLLocationCoordinate2D,
        at secondDate: Date?
    ) -> Double? {
        guard let firstDate, let secondDate else { return nil }
        let seconds = secondDate.timeIntervalSince(firstDate)
        guard seconds > 0 else { return nil }
        let meters = CLLocation(latitude: first.latitude, longitude: first.longitude)
            .distance(from: CLLocation(latitude: second.latitude, longitude: second.longitude))
        return meters / seconds
    }
}
