import SwiftUI
import UIKit
import MapKit

struct TwoFingerDoubleTapAttachment: UIViewRepresentable {
    let onRecognized: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRecognized: onRecognized)
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(
        _ uiView: AttachmentView,
        context: Context
    ) {
        context.coordinator.onRecognized = onRecognized
        uiView.installRecognizerIfNeeded()
    }

    static func dismantleUIView(
        _ uiView: AttachmentView,
        coordinator: Coordinator
    ) {
        uiView.removeRecognizer()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onRecognized: () -> Void

        init(onRecognized: @escaping () -> Void) {
            self.onRecognized = onRecognized
        }

        @objc func didRecognize() {
            onRecognized()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith
                otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    final class AttachmentView: UIView {
        weak var coordinator: Coordinator?
        private weak var installedSuperview: UIView?
        private var recognizer: UITapGestureRecognizer?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            installRecognizerIfNeeded()
        }

        func installRecognizerIfNeeded() {
            guard let superview, let coordinator else { return }
            if installedSuperview === superview, recognizer != nil {
                return
            }
            removeRecognizer()
            let recognizer = UITapGestureRecognizer(
                target: coordinator,
                action: #selector(Coordinator.didRecognize)
            )
            recognizer.numberOfTapsRequired = 2
            recognizer.numberOfTouchesRequired = 2
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = coordinator
            superview.addGestureRecognizer(recognizer)
            installedSuperview = superview
            self.recognizer = recognizer
        }

        func removeRecognizer() {
            if let recognizer {
                installedSuperview?.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            installedSuperview = nil
        }
    }
}

/// UIKit pinch recognizer used in addition to the SwiftUI timeline gestures.
/// `ScrollView` can win the SwiftUI gesture arena on a physical device before
/// `MagnifyGesture` receives a sample. A window-level recognizer is installed
/// after SwiftUI finishes attaching the chart, then restricted to that chart.
/// This keeps pinch available without disabling scrolling or row taps.
struct TwoFingerPinchAttachment: UIViewRepresentable {
    let onChanged: (_ scale: CGFloat, _ anchor: CGFloat) -> Void
    let onEnded: (_ scale: CGFloat, _ anchor: CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        context.coordinator.targetView = view
        return view
    }

    func updateUIView(
        _ uiView: AttachmentView,
        context: Context
    ) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.targetView = uiView
        uiView.installRecognizerIfNeeded()
        // `updateUIView` can run before SwiftUI has attached the representable
        // to a window. Recheck after the current layout transaction so the
        // recognizer is never left on a temporary background container.
        DispatchQueue.main.async { [weak uiView] in
            uiView?.installRecognizerIfNeeded()
        }
    }

    static func dismantleUIView(
        _ uiView: AttachmentView,
        coordinator: Coordinator
    ) {
        uiView.removeRecognizer()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: (_ scale: CGFloat, _ anchor: CGFloat) -> Void
        var onEnded: (_ scale: CGFloat, _ anchor: CGFloat) -> Void
        weak var targetView: UIView?
        private struct ScrollTouchLimitLease {
            let scrollView: UIScrollView
        }

        private struct ScrollTouchLimitOwner {
            let scrollView: UIScrollView
            let originalLimit: Int
            var count: Int
        }

        private static var scrollTouchLimitOwners:
            [ObjectIdentifier: ScrollTouchLimitOwner] = [:]
        private var scrollTouchLimitLeases: [ScrollTouchLimitLease] = []
        private var didLogRecognition = false

        init(
            onChanged: @escaping (_ scale: CGFloat, _ anchor: CGFloat) -> Void,
            onEnded: @escaping (_ scale: CGFloat, _ anchor: CGFloat) -> Void
        ) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        @objc func didChange(_ recognizer: UIPinchGestureRecognizer) {
            guard let targetView else { return }
            let width = max(targetView.bounds.width, 1)
            let location = recognizer.location(in: targetView)
            let anchor = min(1, max(0, location.x / width))
            let scale = max(0.01, recognizer.scale)
            switch recognizer.state {
            case .began:
                didLogRecognition = true
                TaptionPlanDiagnosticsLogger.shared.record(
                    "pinch_recognizer_began",
                    fields: [
                        "host": String(
                            reflecting: type(of: recognizer.view)
                        ),
                        "scale": String(format: "%.3f", scale),
                    ]
                )
                onChanged(scale, anchor)
            case .changed:
                onChanged(scale, anchor)
            case .ended, .cancelled, .failed:
                if didLogRecognition {
                    TaptionPlanDiagnosticsLogger.shared.record(
                        "pinch_recognizer_ended",
                        fields: [
                            "host": String(
                                reflecting: type(of: recognizer.view)
                            ),
                            "state": String(describing: recognizer.state.rawValue),
                            "scale": String(format: "%.3f", scale),
                        ]
                    )
                }
                didLogRecognition = false
                onEnded(scale, anchor)
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith
                otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard let targetView, targetView.window != nil else {
                return false
            }
            return targetView.bounds.contains(touch.location(in: targetView))
        }

        func limitAncestorScrollPans(from view: UIView) {
            restoreScrollTouchLimits()
            var ancestor = view.superview
            while let current = ancestor {
                if let scrollView = current as? UIScrollView {
                    let key = ObjectIdentifier(scrollView)
                    if let owner = Self.scrollTouchLimitOwners[key] {
                        Self.scrollTouchLimitOwners[key] = ScrollTouchLimitOwner(
                            scrollView: owner.scrollView,
                            originalLimit: owner.originalLimit,
                            count: owner.count + 1
                        )
                    } else {
                        Self.scrollTouchLimitOwners[key] = ScrollTouchLimitOwner(
                            scrollView: scrollView,
                            originalLimit: scrollView.panGestureRecognizer
                                .maximumNumberOfTouches,
                            count: 1
                        )
                        scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
                    }
                    scrollTouchLimitLeases.append(
                        ScrollTouchLimitLease(scrollView: scrollView)
                    )
                }
                ancestor = current.superview
            }
        }

        var modifiedScrollCount: Int {
            scrollTouchLimitLeases.count
        }

        func restoreScrollTouchLimits() {
            for lease in scrollTouchLimitLeases {
                let key = ObjectIdentifier(lease.scrollView)
                guard let owner = Self.scrollTouchLimitOwners[key] else {
                    continue
                }
                if owner.count > 1 {
                    Self.scrollTouchLimitOwners[key] = ScrollTouchLimitOwner(
                        scrollView: owner.scrollView,
                        originalLimit: owner.originalLimit,
                        count: owner.count - 1
                    )
                } else {
                    owner.scrollView.panGestureRecognizer
                        .maximumNumberOfTouches = owner.originalLimit
                    Self.scrollTouchLimitOwners.removeValue(forKey: key)
                }
            }
            scrollTouchLimitLeases.removeAll()
        }
    }

    final class AttachmentView: UIView {
        weak var coordinator: Coordinator?
        private weak var installedSuperview: UIView?
        private var recognizer: UIPinchGestureRecognizer?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            installRecognizerIfNeeded()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                removeRecognizer()
            } else {
                installRecognizerIfNeeded()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            installRecognizerIfNeeded()
        }

        func installRecognizerIfNeeded() {
            guard let window, let coordinator else { return }
            if installedSuperview === window, recognizer != nil {
                return
            }
            removeRecognizer()
            coordinator.targetView = self
            coordinator.limitAncestorScrollPans(from: self)
            let recognizer = UIPinchGestureRecognizer(
                target: coordinator,
                action: #selector(Coordinator.didChange(_:))
            )
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = coordinator
            window.addGestureRecognizer(recognizer)
            TaptionPlanDiagnosticsLogger.shared.record(
                "pinch_attachment_installed",
                fields: [
                    "host": String(reflecting: type(of: window)),
                    "ancestor_scroll": String(
                        coordinator.modifiedScrollCount
                    ),
                ]
            )
            installedSuperview = window
            self.recognizer = recognizer
        }

        func removeRecognizer() {
            if let recognizer {
                installedSuperview?.removeGestureRecognizer(recognizer)
            }
            coordinator?.restoreScrollTouchLimits()
            recognizer = nil
            installedSuperview = nil
        }
    }
}
