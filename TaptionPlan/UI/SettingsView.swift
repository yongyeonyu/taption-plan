import MapKit
import SwiftUI

enum SettingsTypography {
    static let accountTitle: CGFloat = 13
    static let rowTitle: CGFloat = 10.5
    static let action: CGFloat = 9.5
    static let value: CGFloat = 9
    static let accountSubtitle: CGFloat = 8.5
    static let sectionTitle: CGFloat = 8.5
    static let rowSubtitle: CGFloat = 7.8
    static let footnote: CGFloat = 8
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var sharedExport: ShareableURL?
    @State private var googleErrorMessage: String?
    @State private var showsDeleteConfirmation = false
    @State private var showsDeleteBackupsConfirmation = false
    @State var customFrequentPlaceName = ""
    @State var restaurantName = ""
    @State var selectedFrequentPlace: FrequentPlace?
    @State var showsSuggestedPlaceKinds = false
    @State var showsUserTransitLocations = false
    @State private var expandedSettingsSections: Set<String> = [
        "나에게 맞추기",
        "화면과 동작",
        "지도",
        "앱 연동",
        "데이터와 개인정보",
    ]

    var body: some View {
        VStack(spacing: 0) {
            DraftTopBar(
                title: "설정",
                trailing: model.integrationStatusSummary,
                textSizeAdjustment: 1
            )

            ScrollView(showsIndicators: false) {
                VStack(spacing: TaptionMenuMetrics.sectionSpacing) {
                    accountCard

                    settingsSection(
                        "나에게 맞추기",
                        summary: "\(RecordClassificationCatalog.categories.count)개 대분류"
                    ) {
                        settingsRow(
                            icon: "person.crop.circle.badge.checkmark",
                            iconBackground: Color(
                                red: 0.93,
                                green: 0.92,
                                blue: 0.97
                            ),
                            iconColor: Color(
                                red: 0.35,
                                green: 0.28,
                                blue: 0.55
                            ),
                            title: "시작 구성",
                            subtitle: "현재 사용하지 않는 메뉴",
                            value: "사용 안 함"
                        ) {
                            model.openInitialSetup()
                        }
                        .disabled(true)
                        .opacity(0.42)
                    }

                    settingsSection(
                        "화면과 동작",
                        summary: "현재 \(TimeScale(timelineLevel: model.settings.startScale).scheduleEquivalent.rawValue)"
                    ) {
                        settingsScaleRow(
                            icon: "chart.bar.xaxis",
                            title: "시간표 시작 화면",
                            subtitle: "하단 시간표 탭을 누를 때",
                            selection: TimeScale(
                                timelineLevel: model.settings.startScale
                            )
                        )
                        settingsToggleRow(
                            icon: "arrow.uturn.forward",
                            title: "마지막 배율 기억",
                            subtitle: "일·주·월의 마지막 선택 유지",
                            isOn: Binding(
                                get: {
                                    model.settings.rememberLastScale
                                },
                                set: { value in
                                    model.setRememberLastScale(value)
                                }
                            )
                        )
                        settingsRow(
                            icon: "pawprint.fill",
                            iconBackground: Color.tpWarningTint,
                            iconColor: Color(red: 0.57, green: 0.38, blue: 0.08),
                            title: "달리는 고양이",
                            subtitle: "위젯 · Live Activity",
                            value: model.selectedCatCoat.shortName
                        ) {
                            model.detail = .catPicker
                        }
                        settingsToggleRow(
                            icon: "figure.walk.motion",
                            title: "동작 줄이기",
                            subtitle: "고양이와 전환 애니메이션 정지",
                            isOn: Binding(
                                get: { model.settings.reduceMotion },
                                set: { value in
                                    model.setReduceMotion(value)
                                }
                            )
                        )
                        settingsRow(
                            icon: "list.bullet.rectangle",
                            title: "분류표 관리",
                            subtitle: "대분류 · 상세활동 · 자동 분류 기준",
                            value: "\(RecordClassificationCatalog.categories.count)개"
                        ) {
                            model.detail = .categoryManager
                        }
                        frequentPlacesRow
                        userTransitLocationsRow
                    }

                    settingsSection(
                        "지도",
                        summary: "WBS · Apple"
                    ) {
                        mapStyleRow
                    }

                    settingsSection(
                        "앱 연동",
                        summary: model.integrationStatusSummary
                    ) {
                        settingsRow(
                            icon: "checkmark.shield",
                            title: "모든 권한 승인",
                            subtitle: "필요한 시스템 권한을 순서대로 요청",
                            value: "확인"
                        ) {
                            model.presentPermissionOnboarding()
                        }
                        settingsToggleRow(
                            icon: "calendar",
                            title: "캘린더",
                            subtitle: "iPhone 캘린더의 Apple · Google · Naver 일정",
                            isOn: Binding(
                                get: {
                                    !model.settings.selectedCalendarIDs.isEmpty
                                        && model.permissionState(
                                            for: .calendar
                                        ).isGranted
                                },
                                set: { enabled in
                                    Task {
                                        await model.setCalendarEnabled(enabled)
                                    }
                                }
                            )
                        )
                        settingsToggleRow(
                            icon: "bell.badge",
                            iconBackground: Color(
                                red: 1.00,
                                green: 0.94,
                                blue: 0.86
                            ),
                            iconColor: Color(
                                red: 0.72,
                                green: 0.39,
                                blue: 0.08
                            ),
                            title: "계획 시작 알림",
                            subtitle: "추가·이동한 계획 시간에 자동 알림",
                            isOn: Binding(
                                get: {
                                    model.settings.notificationsEnabled
                                        && model.permissionState(
                                            for: .notifications
                                        ).isGranted
                                },
                                set: { enabled in
                                    Task {
                                        await model.setNotificationsEnabled(
                                            enabled
                                        )
                                    }
                                }
                            )
                        )
                        settingsToggleRow(
                            icon: "heart.text.square",
                            iconBackground: Color.tpSuccessTint,
                            iconColor: .tpHealthDark,
                            title: "건강 데이터",
                            subtitle: model.healthIntegrationSummary,
                            isOn: Binding(
                                get: { model.settings.healthEnabled },
                                set: { enabled in
                                    Task {
                                        await model.setHealthEnabled(enabled)
                                    }
                                }
                            )
                        )
                        if model.settings.healthEnabled {
                            settingsRow(
                                icon: "arrow.triangle.2.circlepath",
                                iconBackground: Color(
                                    red: 0.96,
                                    green: 0.91,
                                    blue: 0.96
                                ),
                                iconColor: Color(hex: "#C0268E"),
                                title: "HealthKit 전체 동기화",
                                subtitle: model.healthSyncDetail,
                                value: model.healthSyncStatus
                            ) {
                                Task {
                                    await model.synchronizeHealthHistory()
                                }
                            }
                            .disabled(model.isHealthHistorySyncRunning)
                        }
                        watchInstallRow
                        watchAccelerationCollectionRow
                        watchDataSyncRow
                        locationIntegrationRow
                        if let session = model.activeTrackingSession {
                            liveTrackingRow(session)
                        }
                        settingsRow(
                            icon: "location.viewfinder",
                            iconBackground: .tpPlace,
                            iconColor: .tpPlaceDark,
                            title: "GPS 트래킹 권한 안내",
                            subtitle: "닫은 위치 권한 안내를 다시 열기",
                            value: model.permissionState(for: .location)
                                .settingsLabel
                        ) {
                            model.presentPermissionOnboarding(for: .location)
                        }
                        settingsToggleRow(
                            icon: "cloud.sun",
                            iconBackground: .tpWeather,
                            iconColor: .tpWeatherDark,
                            title: "날씨",
                            subtitle: "머문 위치의 실제 날씨 맥락",
                            isOn: Binding(
                                get: { model.settings.weatherEnabled },
                                set: { enabled in
                                    Task {
                                        await model.setWeatherEnabled(enabled)
                                    }
                                }
                            )
                        )
                        WeatherAttributionView()
                            .padding(.leading, 45)
                        cloudSyncRow
                    }

                    settingsSection(
                        "구글 캘린더 연동",
                        summary: "기기 캘린더 · 직접 연동"
                    ) {
                        settingsRow(
                            icon: "calendar.badge.checkmark",
                            title: "기기 캘린더로 보기",
                            subtitle: "아이폰 캘린더에 추가한 구글 계정 일정을 지도에서 봅니다",
                            value: model.permissionState(for: .calendar).isGranted ? "허용됨" : "허용하기"
                        ) {
                            Task { _ = try? await AppleCalendarService().requestFullAccess() }
                        }
                        settingsRow(
                            icon: "globe",
                            title: "구글 계정 직접 연동",
                            subtitle: "구글 로그인으로 Google Calendar 일정을 바로 읽습니다",
                            value: GoogleCalendarAccount.shared.isConnected ? "연결됨" : "연결하기"
                        ) {
                            Task {
                                if GoogleCalendarAccount.shared.isConnected {
                                    await model.disconnectGoogleCalendar()
                                    return
                                }
                                do {
                                    try await GoogleCalendarAccount.shared.connect()
                                } catch GoogleCalendarError.cancelled {
                                    // 사용자가 로그인 창을 닫은 경우는 알림 없이 끝낸다.
                                } catch {
                                    googleErrorMessage = error.localizedDescription
                                }
                            }
                        }
                        .alert(
                            "구글 캘린더 연결",
                            isPresented: Binding(
                                get: { googleErrorMessage != nil },
                                set: { if !$0 { googleErrorMessage = nil } }
                            )
                        ) {
                            Button("확인", role: .cancel) {}
                        } message: {
                            Text(googleErrorMessage ?? "")
                        }
                    }

                    settingsSection(
                        "데이터와 개인정보",
                        summary: "기기 안에 안전하게 저장"
                    ) {
                        settingsRow(
                            icon: "square.and.arrow.up",
                            title: "내 데이터 내보내기",
                            subtitle: "계획·실제·메모·위치 등 전체 기록을 JSON으로 저장",
                            value: ""
                        ) {
                            do {
                                sharedExport = ShareableURL(
                                    url: try model.exportSnapshotURL()
                                )
                            } catch {
                                model.userFacingError = AppLanguagePreference.text(
                                    korean: "데이터 파일을 만들지 못했습니다.",
                                    english: "Couldn't create the data file."
                                )
                            }
                        }
                        settingsRow(
                            icon: "location.square",
                            title: "어제·오늘 센서 원본 내보내기",
                            subtitle: "어제·오늘 위치·이동·기압 센서 원본을 JSON 파일 하나로 공유",
                            value: ""
                        ) {
                            Task {
                                do {
                                    sharedExport = ShareableURL(url: try await model.exportTodaySensorRawURL())
                                } catch {
                                    model.userFacingError = AppLanguagePreference.text(
                                        korean: "오늘 원본 파일을 만들지 못했습니다.",
                                        english: "Couldn't create today's raw data file."
                                    )
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: TaptionSpacing.tight) {
                            settingsRow(
                                icon: "icloud.and.arrow.up",
                                iconBackground: Color(
                                    red: 0.90,
                                    green: 0.95,
                                    blue: 1.00
                                ),
                                iconColor: Color(
                                    red: 0.16,
                                    green: 0.45,
                                    blue: 0.75
                                ),
                                title: "로그 보내기",
                                subtitle: "iPhone · Apple Watch 로그와 직전 비정상 종료 상태를 iCloud Drive > TaptionLogs에 저장",
                                value: model.diagnosticsExportStatus
                            ) {
                                Task { await model.exportDiagnosticsToICloud() }
                            }
                            Text(model.diagnosticsLatestLogSummary)
                                .font(.taption(size: SettingsTypography.footnote))
                                .foregroundStyle(Color.tpSecondary)
                                .padding(.leading, 45)
                        }
                        settingsRow(
                            icon: "trash",
                            iconBackground: Color(
                                red: 1.00,
                                green: 0.92,
                                blue: 0.92
                            ),
                            iconColor: Color(
                                red: 0.72,
                                green: 0.19,
                                blue: 0.16
                            ),
                            title: "모든 데이터 삭제",
                            subtitle: "이 기기와 iCloud의 BOKKI Plan 데이터",
                            value: ""
                        ) {
                            showsDeleteConfirmation = true
                        }
                    }

                    Text("권한은 필요한 기능을 처음 켤 때만 요청하며, 설정에서 언제든 연결을 끊을 수 있습니다.")
                        .font(.taption(size: SettingsTypography.footnote))
                        .foregroundStyle(Color.tpSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 3)

                    versionFooter
                }
                .padding(.horizontal, TaptionMenuMetrics.contentInset)
                .padding(.top, 11)
                .padding(.bottom, DraftBottomBarMetrics.contentInset)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.always)
            .background(Color.tpBackground)
        }
        .onAppear {
            model.refreshAppleWatchConnectionState()
            model.refreshAppUsageAuthorizationState()
            model.refreshFrequentPlaceSuggestion()
        }
        .task {
            await model.refreshPermissions()
        }
        .overlay {
            if model.isRefreshingIntegrations
                || model.isCloudSyncing
                || model.isExportingDiagnostics {
                ProgressView()
                    .controlSize(.small)
                    .padding(12)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .sheet(item: $sharedExport) { value in
            ActivityShareSheet(items: [value.url])
                .onDisappear {
                    try? FileManager.default.removeItem(at: value.url)
                }
        }
        .sheet(isPresented: $showsUserTransitLocations) {
            UserTransitLocationsSettingsView(model: model)
        }
        .confirmationDialog(
            "모든 BOKKI Plan 데이터를 삭제할까요?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("모든 데이터 삭제", role: .destructive) {
                Task { await model.deleteAllUserData() }
            }
            Button(
                AppLanguagePreference.text(
                    korean: "iCloud 백업까지 모두 삭제",
                    english: "Delete iCloud backups too"
                ),
                role: .destructive
            ) {
                // 첫 확인창이 닫힌 뒤에 두 번째 확인창을 띄운다.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    showsDeleteBackupsConfirmation = true
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("계획, 실제 기록, 메모, 자동 이동 기록이 삭제됩니다. 구매 내역과 체험 사용 여부는 유지되며, 이 작업은 되돌릴 수 없습니다.")
        }
        .confirmationDialog(
            AppLanguagePreference.text(
                korean: "iCloud 백업도 영구 삭제할까요?",
                english: "Permanently delete the iCloud backups too?"
            ),
            isPresented: $showsDeleteBackupsConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                AppLanguagePreference.text(
                    korean: "기기 데이터와 iCloud 백업 영구 삭제",
                    english: "Permanently delete device data and backups"
                ),
                role: .destructive
            ) {
                Task { await model.deleteAllUserData(includingBackups: true) }
            }
            Button(AppLanguagePreference.text(korean: "취소", english: "Cancel"), role: .cancel) {}
        } message: {
            Text(AppLanguagePreference.text(
                korean: "이 기기의 모든 기록과 iCloud Drive의 BOKKI Plan 백업 파일이 모두 삭제됩니다. 백업을 지우면 복원할 방법이 없으며, 이 작업은 되돌릴 수 없습니다.",
                english: "All records on this device and every BOKKI Plan backup file in iCloud Drive will be deleted. Once the backups are gone they cannot be restored, and this cannot be undone."
            ))
        }
    }

    private var accountCard: some View {
        Button {
            model.detail = .widgetPreview
        } label: {
            HStack(spacing: TaptionMenuMetrics.sectionSpacing) {
                Image(systemName: "chart.bar.xaxis")
                    .accessibilityHidden(true)
                    .font(.taption(size: 17))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.tpPrimaryFill, in: RoundedRectangle(cornerRadius: TaptionRadius.panel))

                VStack(alignment: .leading, spacing: 2) {
                    Text("내 시간표")
                        .font(
                            .taption(
                                size: SettingsTypography.accountTitle,
                                weight: .bold
                            )
                        )
                        .foregroundStyle(Color.tpInk)
                    Text("iPhone · Apple Watch · iCloud")
                        .font(
                            .taption(
                                size: SettingsTypography.accountSubtitle
                            )
                        )
                        .foregroundStyle(Color.tpSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .accessibilityHidden(true)
                    .font(.taption(size: 12, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }
            .padding(10)
            .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(true)
        .opacity(0.42)
    }

    private func settingsSection<Content: View>(
        _ title: String,
        summary: String = "",
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    if expandedSettingsSections.contains(title) {
                        expandedSettingsSections.remove(title)
                    } else {
                        expandedSettingsSections.insert(title)
                    }
                }
            } label: {
                HStack(spacing: TaptionMenuMetrics.sectionSpacing) {
                    Text(title)
                        .font(
                            .taption(
                                size: SettingsTypography.sectionTitle,
                                weight: .black
                            )
                        )
                        .foregroundStyle(Color.tpInk)
                    Spacer(minLength: 4)
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.taption(size: SettingsTypography.footnote))
                            .foregroundStyle(Color.tpSecondary)
                            .lineLimit(1)
                    }
                    Image(systemName: expandedSettingsSections.contains(title)
                        ? "chevron.up"
                        : "chevron.down")
                        .accessibilityHidden(true)
                        .font(.taption(size: 8, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                }
                .padding(.horizontal, 10)
                .padding(
                    .vertical,
                    TaptionMenuMetrics.sectionHeaderVerticalPadding
                )
                .contentShape(Rectangle())
                .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
            }
            .buttonStyle(.plain)
            .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
            .contentShape(Rectangle())
            .accessibilityLabel("\(title) 설정")
            .accessibilityValue(
                expandedSettingsSections.contains(title) ? "펼침" : "접힘"
            )

            if expandedSettingsSections.contains(title) {
                content()
            }
        }
        .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionRadius.card, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: TaptionRadius.card, style: .continuous))
    }

    private func settingsScaleRow(
        icon: String,
        title: String,
        subtitle: String,
        selection: TimeScale
    ) -> some View {
        Menu {
            ForEach(TimeScale.scheduleCases) { scale in
                Button {
                    model.setStartScale(scale)
                } label: {
                    if scale == selection {
                        Label(scale.rawValue, systemImage: "checkmark")
                    } else {
                        Text(scale.rawValue)
                    }
                }
            }
        } label: {
            settingsRowLabel(
                icon: icon,
                title: title,
                subtitle: subtitle,
                value: selection.rawValue,
                valueIsOn: false
            )
        }
        .buttonStyle(.plain)
    }

    private var mapStyleRow: some View {
        settingsRowLabel(
            icon: "map.fill",
            iconBackground: Color.tpSurfaceCream,
            iconColor: Color.tpReferenceRose,
            title: "지도 스타일",
            subtitle: "지도 화면의 표시 메뉴에서 바꿉니다",
            value: "표시 메뉴",
            valueIsOn: false
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("지도 스타일, 지도 화면의 표시 메뉴에서 선택")
    }

    private func settingsToggleRow(
        icon: String,
        iconBackground: Color = Color(
            red: 0.94,
            green: 0.94,
            blue: 0.95
        ),
        iconColor: Color = .tpSecondary,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: TaptionMenuMetrics.sectionSpacing) {
            Image(systemName: icon)
                .accessibilityHidden(true)
                .font(.taption(size: 13))
                .foregroundStyle(iconColor)
                .frame(width: 24, height: 24)
                .background(
                    iconBackground,
                    in: RoundedRectangle(cornerRadius: TaptionRadius.tight)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(
                        .taption(
                            size: SettingsTypography.rowTitle,
                            weight: .bold
                        )
                    )
                    .foregroundStyle(Color.tpInk)
                Text(subtitle)
                    .font(
                        .taption(size: SettingsTypography.rowSubtitle)
                    )
                    .foregroundStyle(Color.tpSecondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .controlSize(.mini)
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 44)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.tpControlFill)
                .frame(height: 0.5)
        }
    }

    func settingsRow(
        icon: String,
        iconBackground: Color = Color.tpControlFill,
        iconColor: Color = .tpSecondary,
        title: String,
        subtitle: String,
        value: String,
        valueIsOn: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        Button {
            action?()
        } label: {
            settingsRowLabel(
                icon: icon,
                iconBackground: iconBackground,
                iconColor: iconColor,
                title: title,
                subtitle: subtitle,
                value: value,
                valueIsOn: valueIsOn
            )
        }
        .buttonStyle(.plain)
    }

    private func settingsRowLabel(
        icon: String,
        iconBackground: Color = Color(
            red: 0.94,
            green: 0.94,
            blue: 0.95
        ),
        iconColor: Color = .tpSecondary,
        title: String,
        subtitle: String,
        value: String,
        valueIsOn: Bool
    ) -> some View {
        HStack(spacing: TaptionMenuMetrics.sectionSpacing) {
            Image(systemName: icon)
                .accessibilityHidden(true)
                .font(.taption(size: 13))
                .foregroundStyle(iconColor)
                .frame(width: 24, height: 24)
                .background(
                    iconBackground,
                    in: RoundedRectangle(cornerRadius: TaptionRadius.tight)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(
                        .taption(
                            size: SettingsTypography.rowTitle,
                            weight: .bold
                        )
                    )
                    .foregroundStyle(Color.tpInk)
                Text(subtitle)
                    .font(
                        .taption(size: SettingsTypography.rowSubtitle)
                    )
                    .foregroundStyle(Color.tpSecondary)
            }

            Spacer(minLength: 4)

            if !value.isEmpty {
                Text(value)
                    .font(
                        .taption(
                            size: SettingsTypography.value,
                            weight: valueIsOn ? .black : .regular
                        )
                    )
                    .foregroundStyle(
                        valueIsOn
                            ? Color(red: 0.18, green: 0.52, blue: 0.32)
                            : Color.tpSecondary
                    )
            }

            Image(systemName: "chevron.right")
                .accessibilityHidden(true)
                .font(.taption(size: 10, weight: .semibold))
                .foregroundStyle(
                    Color(red: 0.69, green: 0.69, blue: 0.71)
                )
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 44)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.tpControlFill)
                .frame(height: 0.5)
        }
    }
}

private struct ShareableURL: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

private extension TimeScale {
    init(timelineLevel: TimelineLevel) {
        switch timelineLevel {
        case .day: self = .day
        case .week: self = .week
        case .month: self = .month
        case .year: self = .month
        }
    }
}

#Preview {
    SettingsView(model: AppModel())
}
