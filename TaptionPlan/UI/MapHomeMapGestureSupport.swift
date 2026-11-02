import UIKit

/// 지도 엔진이 만든 제스처에 target을 붙여 둔 목록. 지도 안 뷰가 바뀌면 사라진 것은 떼고 새것만 붙인다.
/// Apple 지도와 벡터 지도 코디네이터가 함께 쓴다.
@MainActor
struct MapHomeObservedGestures<Gesture: UIGestureRecognizer> {
    private(set) var gestures: [Gesture] = []

    mutating func refresh(found: [Gesture], target: AnyObject, action: Selector) {
        let currentIDs = Set(found.map { ObjectIdentifier($0) })
        for gesture in gestures where !currentIDs.contains(ObjectIdentifier(gesture)) {
            gesture.removeTarget(target, action: action)
        }
        gestures.removeAll { !currentIDs.contains(ObjectIdentifier($0)) }
        let observedIDs = Set(gestures.map { ObjectIdentifier($0) })
        for gesture in found where !observedIDs.contains(ObjectIdentifier(gesture)) {
            gesture.addTarget(target, action: action)
            gestures.append(gesture)
        }
    }

    mutating func removeAll(target: AnyObject, action: Selector) {
        for gesture in gestures { gesture.removeTarget(target, action: action) }
        gestures.removeAll()
    }
}

enum MapHomeMapGestures {
    static func all(in view: UIView) -> [UIGestureRecognizer] {
        (view.gestureRecognizers ?? []) + view.subviews.flatMap(all)
    }

    static func pans(in view: UIView) -> [UIPanGestureRecognizer] {
        all(in: view).compactMap { $0 as? UIPanGestureRecognizer }
    }

    /// 핀치·회전. 카메라를 직접 움직이는 두 손가락 제스처다.
    static func camera(in view: UIView) -> [UIGestureRecognizer] {
        all(in: view).filter { $0 is UIPinchGestureRecognizer || $0 is UIRotationGestureRecognizer }
    }

    /// 길게 누르기 시작이면 누른 지점을 돌려준다. 두 손가락 이상이면 핀치로 본다.
    static func longPressPoint(_ gesture: UILongPressGestureRecognizer, in view: UIView) -> CGPoint? {
        guard gesture.state == .began, gesture.numberOfTouches <= 1 else { return nil }
        return gesture.location(in: view)
    }
}
