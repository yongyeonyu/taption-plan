import SwiftUI
import TaptionPlanCore

/// 메뉴의 Apple Watch 항목. Watch 앱 설치·버전과 iPhone에서 바꾸는 Watch 설정을 모았다.
struct MapHomeAppleWatchMenuItem: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage

    @State private var isAppleWatchMenuExpanded = false
    @State private var isWatchInstallPresented = false
    @AppStorage(AppleWatchLink.enabledKey) private var isAppleWatchLinkEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.refreshAppleWatchConnectionState()
                isAppleWatchMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    MapHomeMenuIconChip(systemImage: "applewatch", tint: .tpMenuChip("#6FA84F"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.text("Apple Watch 데이터", "Apple Watch data"))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                        Text(appleWatchDataStatusText)
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isAppleWatchMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.tpInk)
                .modifier(MapHomeMenuRowPadding())
                .padding(.horizontal, 12)
                .background(Color.tpInk.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isAppleWatchMenuExpanded {
                Toggle(isOn: $isAppleWatchLinkEnabled) {
                    Text(language.text("Apple Watch 연동", "Apple Watch link"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                }
                .tint(Color.tpAccent)
                .padding(.horizontal, 12)
                .onChange(of: isAppleWatchLinkEnabled) { _, _ in model.applyAppleWatchLinkChange() }
                appleWatchAppSection
                Text(appleWatchHealthStatusText)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                Button {
                    if model.settings.healthEnabled {
                        model.requestWatchDataSync(source: "map_watch_card")
                    } else {
                        Task { await model.requestHealth() }
                    }
                } label: {
                    Text(language.text("지금 가져오기", "Import now")).frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color.tpAccent.opacity(0.10), in: Capsule()).contentShape(Capsule())
                }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
                .foregroundStyle(Color.tpAccent)
                .lineLimit(1)
                .padding(.horizontal, 12)
            }
        }
    }

    private var appleWatchAppStatus: AppleWatchAppStatus {
        AppleWatchAppStatus.make(
            state: model.appleWatchConnectionState,
            version: model.appleWatchAppVersion,
            iPhoneBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        )
    }

    /// 설치·버전과 iPhone에서 바꾸는 Watch 설정.
    @ViewBuilder
    private var appleWatchAppSection: some View {
        switch appleWatchAppStatus {
        case .unavailable:
            EmptyView()
        case .notInstalled:
            appleWatchNote(language.text("Watch 앱 · 설치 안 됨", "Watch app · not installed"))
            appleWatchActionButton(language.text("Watch 앱 설치", "Install Watch app")) { isWatchInstallPresented = true }
        case .installed(let version, let updateAvailable):
            appleWatchNote(version.map { value in
                let text = value.displayText
                return language.text("Watch 앱 · 설치됨 · \(text)", "Watch app · installed · \(text)")
            } ?? language.text("Watch 앱 · 설치됨 · 버전 확인 중", "Watch app · installed · checking version"))
            if updateAvailable {
                appleWatchActionButton(language.text("Watch 앱 업데이트", "Update Watch app")) {
                    if let url = AppleWatchLink.watchAppURL { UIApplication.shared.open(url) }
                }
            }
            appleWatchSettings
        }
    }

    private var appleWatchSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 기록기는 시스템이 계속 돌리므로 켬·끔만 고른다.
            Toggle(isOn: Binding(
                get: { model.settings.watchAccelerationProfile != .off },
                set: { model.setWatchAccelerationProfile($0 ? .balanced : .off) }
            )) {
                Text(language.text("움직임 수집", "Motion collection"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
            }
            .tint(Color.tpAccent)
            Picker(selection: Binding(
                get: { model.settings.watchDataSyncProfile },
                set: { model.setWatchDataSyncProfile($0) }
            )) {
                ForEach(TaptionWatchDataSyncProfile.allCases, id: \.self) { profile in
                    Text(appleWatchSyncTitle(profile)).tag(profile)
                }
            } label: {
                Text(language.text("건강 데이터 보내기", "Send health data"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
            }
            .tint(Color.tpAccent)
        }
        .disabled(!isAppleWatchLinkEnabled)
        .padding(.horizontal, 12)
    }

    private func appleWatchSyncTitle(_ profile: TaptionWatchDataSyncProfile) -> String {
        switch profile {
        case .off: language.text("끔", "Off")
        case .batterySaver: language.text("배터리 최소화", "Battery saver")
        case .balanced: language.text("균형", "Balanced")
        case .accuracy: language.text("최신 데이터 우선", "Latest data first")
        }
    }

    private func appleWatchNote(_ text: String) -> some View {
        Text(text)
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
    }

    private func appleWatchActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Color.tpAccent.opacity(0.10), in: Capsule()).contentShape(Capsule())
        }
        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
        .foregroundStyle(Color.tpAccent)
        .padding(.horizontal, 12)
    }

    /// Watch 앱에서 받은 상태. 건강 앱 조회 시각은 `appleWatchHealthStatusText`에 따로 둔다.
    private var appleWatchDataStatusText: String {
        let status = AppleWatchMenuStatus.make(
            state: model.appleWatchConnectionState,
            linkEnabled: isAppleWatchLinkEnabled,
            lastDataAt: model.appleWatchLastDataReceivedAt
        )
        switch status {
        case .unavailable: return language.text("사용 불가", "Unavailable")
        case .linkOff: return language.text("연동 꺼짐", "Link off")
        case .installNeeded: return language.text("Watch 앱 설치 필요", "Install the Watch app")
        case .waiting(let lastData):
            guard let lastData else { return language.text("수신 대기", "Waiting for data") }
            let stamp = appleWatchStamp(lastData)
            return language.text("수신 대기 · \(stamp)", "Waiting · last \(stamp)")
        case .connected(let lastData):
            guard let lastData else { return language.text("연결됨", "Connected") }
            let stamp = appleWatchStamp(lastData)
            return language.text("연결됨 · \(stamp) 수신", "Connected · received \(stamp)")
        }
    }

    private var appleWatchHealthStatusText: String {
        guard model.settings.healthEnabled else { return language.text("건강 앱 · 권한 필요", "Health · permission needed") }
        guard let fetched = model.lastHealthRefreshAt else { return language.text("건강 앱 · 연결됨", "Health · connected") }
        let stamp = appleWatchStamp(fetched)
        return language.text("건강 앱 · \(stamp) 가져옴", "Health · fetched \(stamp)")
    }

    private func appleWatchStamp(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().hour().minute().locale(language.locale))
    }
}

/// 튜토리얼을 이미 지난 사용자에게도 Watch 앱 설치를 한 번 안내한다(WCH1105A01).
private struct AppleWatchInstallPrompt: ViewModifier {
    @Bindable var model: AppModel
    let isBlocked: Bool
    @State private var isPresented = false

    private var offers: Bool {
        model.appleWatchOnboardingPrompt == .installInvitation && !isBlocked && !model.isAppLocked
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: offers, initial: true) { _, offers in
                if offers { isPresented = true }
            }
            .sheet(isPresented: $isPresented) {
                AppleWatchInstallSheet(model: model, language: MapHomeLanguage.current)
            }
    }
}

extension View {
    func appleWatchInstallPrompt(model: AppModel, isBlocked: Bool) -> some View {
        modifier(AppleWatchInstallPrompt(model: model, isBlocked: isBlocked))
    }
}
