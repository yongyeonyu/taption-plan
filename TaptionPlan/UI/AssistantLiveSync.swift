import Foundation
import SwiftUI
import UIKit

/// 앱이 전면에 있는 동안 AI 비서 명령·여행 계획을 짧은 간격으로 확인하는 값(RTA1120A01, 대표 결정 2026-11-20).
/// 기본 3초, 통화 중 빠른 모드 1초, 끔이면 예전처럼 5분. 3·1·300은 이 파일 밖에 흩어 쓰지 않는다.
enum AgentSyncMode: String, CaseIterable, Identifiable {
    case off, three, one
    var id: String { rawValue }
}

/// 갱신 입구 하나(`refresh`). 폴링·푸시·수동 새로고침이 모두 여기로 들어오고, 나중에 WebSocket으로 갈아끼워도 호출부는 같다.
@MainActor
@Observable
final class AssistantLiveSync {
    static let shared = AssistantLiveSync()

    nonisolated static let modeKey = "assistantLiveSyncMode"
    nonisolated static let oneStartedKey = "assistantLiveSyncOneAt"
    /// 1초 모드는 켜고 이만큼 지나면 3초로 돌아온다(통화가 끝났는데 1초가 남지 않게).
    nonisolated static let oneAutoBack: TimeInterval = 30 * 60
    nonisolated static let threeSeconds: TimeInterval = 3
    nonisolated static let oneSecond: TimeInterval = 1
    /// 과열(serious 이상)에서 짧은 모드가 내려가는 값.
    nonisolated static let hotSeconds: TimeInterval = 10
    /// 연속 실패가 이만큼 쌓이면 한 줄을 띄우고, 같은 줄은 `noticeEvery`에 한 번만.
    nonisolated static let failuresBeforeNotice = 3
    nonisolated static let noticeEvery: TimeInterval = 300

    // MARK: 값 계산(시험 대상)

    nonisolated static func interval(mode: AgentSyncMode, lowPower: Bool, thermal: ProcessInfo.ThermalState) -> TimeInterval {
        let hot = thermal == .serious || thermal == .critical
        switch mode {
        case .off: return AssistantCommandPolling.idleInterval
        case .three: return hot ? hotSeconds : threeSeconds
        case .one: return hot ? hotSeconds : (lowPower ? threeSeconds : oneSecond)
        }
    }

    /// 저장된 모드. 1초는 켠 지 30분이 지나면 3초로 돌려 저장한다.
    nonisolated static func mode(defaults: UserDefaults = .standard, now: Date = .now) -> AgentSyncMode {
        let stored = defaults.string(forKey: modeKey).flatMap(AgentSyncMode.init(rawValue:)) ?? .three
        guard stored == .one else { return stored }
        let started = defaults.object(forKey: oneStartedKey) as? Date
        if let started, now.timeIntervalSince(started) < oneAutoBack { return .one }
        defaults.set(AgentSyncMode.three.rawValue, forKey: modeKey)
        return .three
    }

    nonisolated static func setMode(_ mode: AgentSyncMode, defaults: UserDefaults = .standard, now: Date = .now) {
        defaults.set(mode.rawValue, forKey: modeKey)
        if mode == .one { defaults.set(now, forKey: oneStartedKey) } else { defaults.removeObject(forKey: oneStartedKey) }
    }

    /// 무거운 곁일(규칙·영수증 등)은 예전 5분 경로에 둔다.
    nonisolated static func heavyDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= AssistantCommandPolling.idleInterval
    }

    // MARK: 열린 화면

    /// 지금 열린 반영 대상 화면(여행 등)과 편집 중인 화면.
    private(set) var screens: [String: Int] = [:]
    private(set) var editing = 0
    func hold(_ screen: String) { screens[screen, default: 0] += 1 }
    func release(_ screen: String) {
        guard let n = screens[screen] else { return }
        if n <= 1 { screens[screen] = nil } else { screens[screen] = n - 1 }
    }
    func beginEditing() { editing += 1 }
    func endEditing() { editing = max(editing - 1, 0) }

    // MARK: 여행 계획 카드

    /// 통화 중 `/plan`으로 도착한 새 계획. 여행 화면이 카드로 묻고, 「반영」을 누르면 `acceptedPlan`이 된다.
    var pendingPlan: String?
    var acceptedPlan: String?

    /// 처음 보는 계획만 카드로 올린다. 같은 내용은 다시 올리지 않는다.
    func offer(plan text: String, defaults: UserDefaults = .standard) {
        guard pendingPlan != text, TripRelay.isNew(text, defaults: defaults) else { return }
        pendingPlan = text
    }

    func acceptPlan() {
        guard let text = pendingPlan else { return }
        pendingPlan = nil
        acceptedPlan = text
    }

    func dismissPlan() { pendingPlan = nil }

    // MARK: 확인

    enum Reason { case poll, push, manual }

    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var lastHeavyAt: Date?
    @ObservationIgnored private(set) var failures = 0
    @ObservationIgnored private var lastNoticeAt: Date?
    @ObservationIgnored private var noticeShown: String?

    struct Hooks {
        var commands: (_ light: Bool) async -> Void
        var plan: () async -> Void
        var failed: () -> Bool

        @MainActor static func live(language: MapHomeLanguage) -> Hooks {
            Hooks(
                commands: { light in await AssistantCommandRefresh.now(language: language, light: light) },
                plan: {
                    guard TripRelay.isAvailable, TripRelay.key != nil, let text = await TripRelay.fetch() else { return }
                    AssistantLiveSync.shared.offer(plan: text)
                },
                failed: { AssistantCommandRunner.lastFetchFailed }
            )
        }
    }

    /// 갱신 입구. 겹치면 건너뛰고, 편집 중이면 명령을 반영하지 않고 다음 주기로 미룬다(서버 큐에 그대로 둔다).
    func refresh(reason: Reason, language: MapHomeLanguage, hooks: Hooks? = nil, now: Date = .now) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let hooks = hooks ?? .live(language: language)
        if editing > 0 && reason == .poll {
            noteDeferred(language: language)
            return
        }
        let heavy = reason == .manual || Self.heavyDue(last: lastHeavyAt, now: now)
        if heavy { lastHeavyAt = now }
        await hooks.commands(!heavy)
        if screens["travel"] != nil { await hooks.plan() }
        record(failed: hooks.failed(), language: language, now: now)
    }

    private func noteDeferred(language: MapHomeLanguage) {
        let text = language.text("편집 중이라 잠시 미뤘어요", "Paused while you edit")
        AssistantInbox.current.show(text)
        noticeShown = text
    }

    /// 연속 3회 실패하면 한 줄을 띄우고, 성공하면 거둔다.
    func record(failed: Bool, language: MapHomeLanguage, now: Date) {
        guard failed else {
            failures = 0
            if let shown = noticeShown, AssistantInbox.current.notice == shown { AssistantInbox.current.show(nil) }
            noticeShown = nil
            return
        }
        failures += 1
        guard failures >= Self.failuresBeforeNotice, lastNoticeAt.map({ now.timeIntervalSince($0) >= Self.noticeEvery }) ?? true else { return }
        lastNoticeAt = now
        let text = language.text("AI 연결을 확인하지 못했어요", "Couldn't reach the AI connection")
        AssistantInbox.current.show(text)
        noticeShown = text
    }

    // MARK: 반복

    /// 전면에서만 돈다. 깸 자체를 간격에 맞추고, 확인이 길어져도 쌓이지 않는다(끝난 뒤 다음 깸).
    static func runLoop(
        isActive: @MainActor () -> Bool,
        interval: @MainActor () -> TimeInterval,
        wait: (TimeInterval) async -> Void,
        refresh: @MainActor () async -> Void
    ) async {
        while !Task.isCancelled {
            let seconds = interval()
            await wait(seconds)
            guard !Task.isCancelled, isActive() else { return }
            await refresh()
        }
    }

    static func liveInterval(info: ProcessInfo = .processInfo) -> TimeInterval {
        interval(mode: mode(), lowPower: info.isLowPowerModeEnabled, thermal: info.thermalState)
    }
}

/// 여행 화면 같은 반영 대상 화면이 열려 있는 동안 알린다. 편집 시트는 `editing`으로 알려 반영을 미룬다.
private struct AssistantLiveScreenModifier: ViewModifier {
    let screen: String
    let language: MapHomeLanguage?
    func body(content: Content) -> some View {
        content
            .onAppear { AssistantLiveSync.shared.hold(screen) }
            .onDisappear { AssistantLiveSync.shared.release(screen) }
            .overlay(alignment: .top) {
                if let language { AssistantPlanArrivalCard(language: language) }
            }
    }
}

private struct AssistantEditingModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { AssistantLiveSync.shared.beginEditing() }
            .onDisappear { AssistantLiveSync.shared.endEditing() }
    }
}

extension View {
    /// 여행 화면: 열려 있는 동안 `/plan`도 같은 주기로 확인하고, 새 계획이 오면 카드를 띄운다.
    func assistantLiveTravelScreen(language: MapHomeLanguage) -> some View {
        modifier(AssistantLiveScreenModifier(screen: "travel", language: language))
    }

    /// 편집 시트: 열려 있는 동안 AI 명령 반영을 다음 주기로 미룬다.
    func assistantLiveEditing() -> some View { modifier(AssistantEditingModifier()) }
}

/// 통화 중 계획 전체가 오면 덮어쓰지 않고 묻는다(대표가 앱에서 고친 내용을 지우지 않게).
struct AssistantPlanArrivalCard: View {
    let language: MapHomeLanguage
    @State private var sync = AssistantLiveSync.shared

    var body: some View {
        if sync.pendingPlan != nil {
            HStack(spacing: 10) {
                Text(language.text("새 계획이 도착했어요", "A new plan arrived"))
                    .font(.taptionStyle(.subheadline).weight(.semibold))
                Spacer(minLength: 4)
                Button(language.text("나중에", "Later")) { sync.dismissPlan() }
                    .buttonStyle(.bordered)
                Button(language.text("반영", "Apply")) { sync.acceptPlan() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onAppear { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        }
    }
}

/// 「AI 연결」의 실시간 반영 줄(끔 / 3초 / 1초).
struct AssistantLiveSyncSettingRow: View {
    let language: MapHomeLanguage
    @State private var mode = AssistantLiveSync.mode()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(language.text("실시간 반영", "Live updates"), selection: $mode) {
                Text(language.text("끔", "Off")).tag(AgentSyncMode.off)
                Text(language.text("3초", "3 s")).tag(AgentSyncMode.three)
                Text(language.text("1초", "1 s")).tag(AgentSyncMode.one)
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { _, next in AssistantLiveSync.setMode(next) }
            Text(language.text("1초는 통화 중 빠른 모드로, 30분 뒤 3초로 돌아와요. 저전력 모드에서는 3초로 확인해요.",
                               "1 s is a fast mode for calls and returns to 3 s after 30 minutes. Low Power Mode checks every 3 s."))
                .font(.taptionStyle(.caption))
                .foregroundStyle(.secondary)
        }
    }
}
