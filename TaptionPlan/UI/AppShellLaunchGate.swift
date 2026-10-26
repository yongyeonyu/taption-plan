import Foundation

/// 시작 화면 진행선의 수학. 목표에 지수적으로 다가가되 최소 걸음은 보장한다.
///
/// 예전에는 목표에 가까워질수록 걸음이 0에 수렴해 진행선이 0.86에서 얼어붙었다가
/// 준비가 끝날 때 1.0으로 점프했다. 지금은 목표에 닿았는데 준비가 안 끝났으면
/// 화면 쪽에서 목표를 조금씩 밀어 올린다(`AppShellView.startInitialLaunchProgressTicker`).
/// 저장소 적재 전에는 0.90, 적재 뒤 지도만 남았으면 0.97이 천장이다. 97%는 "거의
/// 끝났다"는 뜻이지 "더 채울 게 없다"는 뜻이 아니므로, 읽는 내내 97%에 두면 멈춘 것처럼 보인다.
enum AppShellInitialLaunchProgressMath {
    /// 준비를 기다리는 동안 진행선이 기어갈 수 있는 천장.
    ///
    /// 저장소 적재가 끝나기 전에는 0.90이다. 예전에는 적재가 도는 내내 0.97까지
    /// 밀어 올려서, 데이터를 읽는 몇 초 동안 화면이 "97%에서 멈춘" 것처럼 보였다
    /// (대표 지적, 2026-10-26). 적재가 끝나면 남은 일은 지도 첫 화면뿐이라
    /// 0.97까지 올려도 된다.
    static func crawlCap(bootstrapped: Bool) -> Double {
        bootstrapped ? 0.97 : 0.90
    }

    /// 이번 박자에 진행선이 향할 곳. 목표에 닿기 전에는 목표로 곧장 가고,
    /// 닿은 뒤에는 천장까지 3%씩 기어간다. 목표가 천장보다 높아도(0.96·0.98은
    /// 저장소 적재가 끝나기 전에 불린다) 천장이 막는다. 1.0만 예외다 — 그건
    /// 스플래시를 걷는 순간이라 기어갈 이유가 없다.
    static func goal(current: Double, target: Double, bootstrapped: Bool) -> Double {
        guard target < 1 else { return 1 }
        let cap = crawlCap(bootstrapped: bootstrapped)
        let clamped = min(cap, target)
        guard current >= clamped else { return clamped }
        return min(cap, current + 0.03)
    }

    static func next(
        current: Double,
        target: Double,
        minimumStep: Double = 0.004
    ) -> Double {
        let current = min(max(current, 0), 1)
        let target = min(max(target, current), 1)
        guard target > current else { return current }
        let step = max(minimumStep, (target - current) * 0.18)
        return min(target, current + step)
    }
}

/// 시작 화면(스플래시)을 걷어도 되는지 판단한다.
///
/// 앱을 쓸 수 있는 상태 — 상점 잠금 해제 확인, 보안 상태, 첫 화면 렌더, 저장소 적재 —
/// 가 모두 갖춰져야 한다. 지도 첫 화면(`hasCompletedInitialMapShellPreparation`)은
/// 오늘 경로까지 그려졌다는 뜻이라 조금 더 걸리므로, 유예(`mapShellGraceElapsed`)가
/// 지나면 그것 없이도 연다. 접근 권한이 없으면(상점 잠금) 지도 자체를 그리지 않으므로
/// 두 조건을 모두 건너뛴다.
enum AppShellInitialLaunchGate {
    static func isReady(
        hasCompletedInitialProRefresh: Bool,
        isSecurityStateReady: Bool,
        hasRenderedInitialDestination: Bool,
        hasCompletedInitialMapShellPreparation: Bool,
        mapShellGraceElapsed: Bool = false,
        isBootstrapped: Bool,
        grantsAccess: Bool
    ) -> Bool {
        hasCompletedInitialProRefresh
            && isSecurityStateReady
            && hasRenderedInitialDestination
            && (hasCompletedInitialMapShellPreparation
                || mapShellGraceElapsed
                || !grantsAccess)
            && (isBootstrapped || !grantsAccess)
    }
}

/// 생체 인증을 이번 잠금 세대에서 이미 시도했는지 판단한다(같은 세대에서 두 번 묻지 않는다).
struct AppLockBiometricAttemptGate {
    static func shouldStart(
        generation: Int,
        attemptedGeneration: Int?,
        isInFlight: Bool
    ) -> Bool {
        !isInFlight && attemptedGeneration != generation
    }
}

/// 시작 게이트가 하나씩 열릴 때마다 걸린 시간을 남긴다.
///
/// "시작이 너무 길다"는 지적을 재려면 어느 단계가 마지막까지 남는지 알아야 한다.
/// `initial_launch_ready`의 `duration_ms`는 합계만 주므로, 단계별로 남겨 다음에
/// 무엇을 손댈지 바로 보이게 한다. 값은 단조 시계라 기록 순서와 무관하다.
enum AppShellLaunchGateRecorder {
    static func record(_ gate: String, startedAt: TimeInterval?) {
        // 첫 화면이 그려진 시점(onAppear)은 시작 과제(.task)보다 빠를 수 있다.
        // 그때는 0으로 적어 "시작 전에 이미 끝난 단계"로 읽히게 한다.
        let elapsed = startedAt.map {
            ProcessInfo.processInfo.systemUptime - $0
        } ?? 0
        TaptionPlanDiagnosticsLogger.shared.record(
            "launch_gate",
            fields: [
                "gate": gate,
                "elapsed_ms": String(Int(elapsed * 1_000)),
            ]
        )
    }
}
