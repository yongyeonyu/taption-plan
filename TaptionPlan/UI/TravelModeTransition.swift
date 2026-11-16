import SwiftUI
import UIKit

/// 일상 ↔ 여행 전환(STY1116A01)의 순수 계산: 단계와 원 반지름.
enum TravelModeTransition {
    enum Phase: Equatable { case closed, opening, open, closing }
    enum Event: Equatable { case requestOpen, requestClose, revealFinished, concealFinished }
    /// 화면이 할 일. `present`·`remove`는 덮개를 움직임 없이 올리고 내린다.
    enum Effect: Equatable { case none, present, reveal, conceal, remove }

    static let openDuration = 0.5 * timeScale
    static let closeDuration = 0.42 * timeScale
    /// 화면 사진을 찍는 시험에서만 `-slowTravelTransition`으로 늦춘다.
    static let timeScale: Double = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-slowTravelTransition") { return 8 }
        #endif
        return 1
    }()
    /// 「동작 줄이기」에서 쓰는 크로스페이드.
    static let fadeDuration = 0.2

    /// 두 번 누름·닫는 중 다시 열기·늦게 온 끝남 신호를 여기서 걸러 낸다.
    static func reduce(_ phase: inout Phase, _ event: Event) -> Effect {
        switch (phase, event) {
        case (.closed, .requestOpen):
            phase = .opening
            return .present
        case (.closing, .requestOpen):
            phase = .opening
            return .reveal
        case (.opening, .requestClose), (.open, .requestClose):
            phase = .closing
            return .conceal
        case (.opening, .revealFinished):
            phase = .open
            return .none
        case (.closing, .concealFinished):
            phase = .closed
            return .remove
        default:
            return .none
        }
    }

    /// 누른 자리에서 화면의 가장 먼 모서리까지. 이만큼 퍼지면 화면이 다 드러난다.
    static func revealRadius(from origin: CGPoint, in size: CGSize) -> CGFloat {
        let dx = max(origin.x, size.width - origin.x)
        let dy = max(origin.y, size.height - origin.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 단추 자리를 모르면(초대로 저절로 열릴 때 등) 화면 가운데에서 퍼진다.
    static func origin(buttonFrame: CGRect?, in size: CGSize) -> CGPoint {
        guard let frame = buttonFrame, !frame.isEmpty,
              CGRect(origin: .zero, size: size).intersects(frame) else {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }
        return CGPoint(x: frame.midX, y: frame.midY)
    }
}

/// 전환 단추의 화면 자리. 관찰하지 않는 값이라 배치가 바뀌어도 화면을 다시 그리지 않는다.
@MainActor
enum TravelModeTransitionOrigin {
    static var buttonFrame: CGRect?
}

extension View {
    /// 전환 단추에 붙여 원이 퍼질 자리를 적어 둔다.
    func travelModeTransitionOrigin() -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { TravelModeTransitionOrigin.buttonFrame = $0 }
    }

    /// `fullScreenCover`와 같은 모달이되, 아래에서 올라오지 않고 전환 단추 자리에서 원으로 드러난다.
    func travelModeCover<Cover: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Cover) -> some View {
        modifier(TravelModeCoverModifier(isPresented: isPresented, cover: content))
    }
}

@MainActor @Observable
private final class TravelModeTransitionDriver {
    var phase = TravelModeTransition.Phase.closed
    var isCoverShown = false
    /// 덮개 안 화면이 따라가는 목표: 다 드러남 / 다 가려짐.
    var isRevealed = false

    func send(_ event: TravelModeTransition.Event) {
        switch TravelModeTransition.reduce(&phase, event) {
        case .none: break
        case .present:
            isRevealed = false
            setCover(true)
        case .reveal: isRevealed = true
        case .conceal: isRevealed = false
        case .remove: setCover(false)
        }
    }

    /// 덮개를 움직임 없이 올리고 내린다. 시스템 기본 올라오는 움직임을 끄고, 다음 틱에 되돌려 안쪽 애니메이션은 살린다.
    private func setCover(_ shown: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        UIView.setAnimationsEnabled(false)
        withTransaction(transaction) { isCoverShown = shown }
        // 덮개 안 화면이 나타나면 되돌린다. 나타나지 않는 경우를 위해 0.5초 뒤에도 되돌린다.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            UIView.setAnimationsEnabled(true)
        }
    }
}

private struct TravelModeCoverModifier<Cover: View>: ViewModifier {
    @Binding var isPresented: Bool
    let cover: () -> Cover
    @State private var driver = TravelModeTransitionDriver()

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented, initial: true) { _, wanted in
                driver.send(wanted ? .requestOpen : .requestClose)
            }
            .fullScreenCover(isPresented: coverBinding) {
                TravelModeReveal(driver: driver, content: cover)
                    .background(TravelCoverAccessibilityGuard())
                    .presentationBackground(.clear)
            }
    }

    /// 안에서 `dismiss()`를 부르면 바로 내리지 않고 오므라든 뒤에 내린다.
    private var coverBinding: Binding<Bool> {
        Binding {
            driver.isCoverShown
        } set: { shown in
            if !shown, isPresented { isPresented = false }
        }
    }
}

private struct TravelModeReveal<Content: View>: View {
    let driver: TravelModeTransitionDriver
    let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0
    @State private var run = 0

    var body: some View {
        content()
            .opacity(reduceMotion ? progress : 1)
            .mask { mask.ignoresSafeArea() }
            // 움직이는 동안에는 아래 화면이 눌리지 않게 한다.
            .allowsHitTesting(driver.phase == .open)
            // 올리는 순간의 「애니메이션 끔」 거래 밖에서 퍼지기 시작해야 움직임이 보인다.
            .task {
                try? await Task.sleep(for: .milliseconds(40))
                UIView.setAnimationsEnabled(true)
                driver.isRevealed = true
            }
            .onChange(of: driver.isRevealed, initial: true) { _, revealed in animate(revealed) }
    }

    /// 다 열린 뒤와 「동작 줄이기」에서는 가리지 않는 사각형이라 원을 그리지 않는다.
    @ViewBuilder private var mask: some View {
        if reduceMotion || driver.phase == .open {
            Rectangle()
        } else {
            GeometryReader { proxy in
                let origin = TravelModeTransition.origin(buttonFrame: TravelModeTransitionOrigin.buttonFrame, in: proxy.size)
                let radius = TravelModeTransition.revealRadius(from: origin, in: proxy.size)
                Circle()
                    .frame(width: radius * 2, height: radius * 2)
                    .scaleEffect(max(progress, 0.001))
                    .position(origin)
            }
        }
    }

    private func animate(_ revealed: Bool) {
        run += 1
        let current = run
        let animation: Animation = reduceMotion
            ? .easeInOut(duration: TravelModeTransition.fadeDuration)
            : revealed ? .easeOut(duration: TravelModeTransition.openDuration) : .easeIn(duration: TravelModeTransition.closeDuration)
        withAnimation(animation) {
            progress = revealed ? 1 : 0
        } completion: {
            // 중간에 방향이 바뀌었으면 앞선 움직임의 끝남 신호는 버린다.
            guard current == run else { return }
            driver.send(revealed ? .revealFinished : .concealFinished)
        }
    }
}

/// 덮개 바탕이 투명해 아래 홈이 접근성 트리(VoiceOver·UI 시험)에 남는다(MRG1117A01).
/// 덮개가 창에 붙어 있는 동안 덮개를 띄운 화면의 접근성 요소를 숨기고, 떨어지면 되돌린다.
private struct TravelCoverAccessibilityGuard: UIViewRepresentable {
    func makeUIView(context: Context) -> GuardView { GuardView() }
    func updateUIView(_ uiView: GuardView, context: Context) {}
    static func dismantleUIView(_ uiView: GuardView, coordinator: ()) { uiView.restore() }

    final class GuardView: UIView {
        private weak var hiddenView: UIView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return restore() }
            guard hiddenView == nil, let presenting = presentedController?.presentingViewController?.view else { return }
            presenting.accessibilityElementsHidden = true
            hiddenView = presenting
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }

        func restore() {
            hiddenView?.accessibilityElementsHidden = false
            hiddenView = nil
        }

        private var presentedController: UIViewController? {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UIViewController { return controller }
                responder = next
            }
            return nil
        }
    }
}

/// 전환 단추 아이콘. 「누르면 가는 곳」을 보인다: 일상에서는 비행기, 여행에서는 집. 바뀔 때 작아졌다 커지며 갈아 끼운다.
struct TravelModeSwitchIcon: View {
    let goesToTravel: Bool
    var size: CGFloat = 25
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            TaptionBarIcon(systemImage: goesToTravel ? "airplane" : "house.fill", size: size)
                .id(goesToTravel)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0.3), value: goesToTravel)
    }
}
