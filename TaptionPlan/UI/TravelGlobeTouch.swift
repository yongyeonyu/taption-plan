import SwiftUI
import TaptionPlanStore

/// 지구본 손가락 조작의 계산(TVE1112A01).
enum TravelGlobeTouch {
    /// 손가락이 간 만큼 지구가 따라 돈다(확대할수록 같은 거리에 덜 돈다). 극을 넘지 않게 위도 ±80°에서 멈춘다.
    static func rotated(_ camera: TravelGlobeCamera, by translation: CGSize) -> TravelGlobeCamera {
        let degreesPerPoint = 180 / (Double.pi * max(1, camera.radius))
        var longitude = camera.longitude - Double(translation.width) * degreesPerPoint
        longitude = (longitude + 180).truncatingRemainder(dividingBy: 360)
        if longitude < 0 { longitude += 360 }
        return TravelGlobeCamera(
            longitude: longitude - 180,
            latitude: min(80, max(-80, camera.latitude + Double(translation.height) * degreesPerPoint)),
            radius: camera.radius
        )
    }

    /// 벌린 배율만큼 확대. 지구본 기본 크기의 0.6배보다 작아지거나 거리 단위보다 가까워지지 않는다.
    static func zoomed(_ radius: Double, by magnification: CGFloat, rest: Double) -> Double {
        min(60_000, max(rest * 0.6, radius * Double(magnification)))
    }

    /// 누른 자리의 깃발. 깃대(발에서 위로 32pt)와 깃발 천 둘레 22pt 안이면 그 깃발이다. 여럿이면 가까운 것.
    static func flag(at location: CGPoint, flags: [TravelGlobeRenderer.Flag], camera: TravelGlobeCamera, size: CGSize) -> String? {
        var best: (id: String, distance: CGFloat)?
        for flag in flags {
            guard let foot = TravelGlobeRenderer.foot(of: flag, camera: camera, size: size) else { continue }
            let nearestX = min(max(location.x, foot.x), foot.x + 20)
            let nearestY = min(max(location.y, foot.y - 32), foot.y)
            let distance = hypot(location.x - nearestX, location.y - nearestY)
            if distance <= 22, distance < (best?.distance ?? .infinity) { best = (flag.id, distance) }
        }
        return best?.id
    }
}
