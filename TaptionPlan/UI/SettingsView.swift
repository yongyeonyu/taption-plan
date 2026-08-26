import MapKit
import SwiftUI

private enum SettingsTypography {
    static let accountTitle: CGFloat = 13
    static let cardTitle: CGFloat = 12
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
    @State private var showsDeleteConfirmation = false
    @State private var customFrequentPlaceName = ""
    @State private var selectedFrequentPlace: FrequentPlace?
    @State private var showsSuggestedPlaceKinds = false
    @State private var showsUserTransitLocations = false
    @State private var expandedSettingsSections: Set<String> = [
        "나에게 맞추기",
        "화면과 동작",
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
                VStack(spacing: 9) {
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
                            iconBackground: Color(red: 1.00, green: 0.95, blue: 0.85),
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
                        "앱 연동",
                        summary: model.integrationStatusSummary
                    ) {
                        settingsToggleRow(
                            icon: "calendar",
                            title: "캘린더",
                            subtitle: "Apple · Google 캘린더 일정 가져오기",
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
                            iconBackground: Color(red: 0.93, green: 0.96, blue: 0.91),
                            iconColor: .tpHealthDark,
                            title: "건강 · Apple Watch",
                            subtitle: model.appleWatchIntegrationSummary,
                            isOn: Binding(
                                get: { model.settings.healthEnabled },
                                set: { enabled in
                                    Task {
                                        await model.setHealthEnabled(enabled)
                                    }
                                }
                            )
                        )
                        watchInstallRow
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
                        sensorCollectionProfileRow
                        watchAccelerationCollectionRow
                        watchDataSyncRow
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
                        cloudSyncRow
                    }

                    settingsSection(
                        "데이터와 개인정보",
                        summary: "기기 안에 안전하게 저장"
                    ) {
                        settingsRow(
                            icon: "square.and.arrow.up",
                            title: "내 데이터 내보내기",
                            subtitle: "계획·실제·메모를 JSON으로 저장",
                            value: ""
                        ) {
                            do {
                                sharedExport = ShareableURL(
                                    url: try model.exportSnapshotURL()
                                )
                            } catch {
                                model.userFacingError =
                                    "데이터 파일을 만들지 못했습니다."
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
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
                                subtitle: "iPhone · Apple Watch 진단 로그를 iCloud Drive > TaptionLogs에 저장",
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
                            subtitle: "이 기기와 iCloud의 Taption Plan 데이터",
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
                .padding(.horizontal, 13)
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
        }
        .sheet(isPresented: $showsUserTransitLocations) {
            UserTransitLocationsSettingsView(model: model)
        }
        .confirmationDialog(
            "모든 Taption Plan 데이터를 삭제할까요?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("모든 데이터 삭제", role: .destructive) {
                Task { await model.deleteAllUserData() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("계획, 실제 기록, 메모, 자동 이동 기록이 삭제됩니다. 이 작업은 되돌릴 수 없습니다.")
        }
    }

    private var cloudSyncRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            settingsRow(
                icon: "icloud",
                iconBackground: Color(red: 0.90, green: 0.95, blue: 1.00),
                iconColor: Color(red: 0.16, green: 0.45, blue: 0.75),
                title: "iCloud 동기화",
                subtitle: "계획·분류·메모를 내 기기 사이에 보관",
                value: model.cloudStatusText,
                valueIsOn: model.permissionState(for: .cloud).isGranted
            ) {
                Task { await model.synchronizeCloud() }
            }
            if let guidance = model.cloudStatusGuidance {
                Text(guidance)
                    .font(.taption(size: SettingsTypography.footnote))
                    .foregroundStyle(Color.tpSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 37)
            }
        }
    }

    private var watchInstallRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            settingsRow(
                icon: "applewatch",
                iconBackground: Color(red: 0.91, green: 0.92, blue: 0.95),
                iconColor: Color.tpInk,
                title: "Apple Watch 앱",
                subtitle: model.appleWatchCompanionRow.subtitle,
                value: model.appleWatchCompanionRow.value
            ) {
                model.refreshAppleWatchConnectionState()
            }
            if let detail = model.appleWatchCompanionRow.detail {
                Text(detail)
                    .font(.taption(size: SettingsTypography.footnote))
                    .foregroundStyle(Color.tpSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 37)
            }
            if let launchReport = model.watchLaunchReport {
                watchLaunchReportView(launchReport)
            }
        }
    }

    private func watchLaunchReportView(
        _ value: (report: String, receivedAt: Date)
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text("Watch 실행 기록")
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                Text(
                    value.receivedAt,
                    format: .dateTime.month().day().hour().minute()
                )
                .font(.taption(size: 8))
                .foregroundStyle(Color.tpSecondary)
                Spacer(minLength: 4)
                Button("복사") {
                    UIPasteboard.general.string = value.report
                }
                .font(.taption(size: 8, weight: .bold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.tpInk)
                Button("지우기") {
                    model.clearWatchLaunchReport()
                }
                .font(.taption(size: 8, weight: .bold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.tpSecondary)
            }
            Text(value.report)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Color.tpInk)
                .textSelection(.enabled)
                .lineLimit(12)
        }
        .padding(.leading, 37)
    }

    private var locationIntegrationRow: some View {
        HStack(spacing: 8) {
            Button {
                guard model.settings.locationEnabled else { return }
                model.selectedTab = .schedule
                model.detail = .locationTimeline
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.taption(size: 14))
                        .foregroundStyle(Color.tpPlaceDark)
                        .frame(width: 27, height: 27)
                        .background(
                            Color.tpPlace,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            Text("이동·위치 트래킹")
                                .font(
                                    .taption(
                                        size: SettingsTypography.rowTitle,
                                        weight: .bold
                                    )
                                )
                                .foregroundStyle(Color.tpInk)
                            if model.settings.locationEnabled {
                                Image(systemName: "chevron.right")
                                    .font(.taption(size: 6.5, weight: .bold))
                                    .foregroundStyle(Color.tpSecondary)
                            }
                        }
                        Text(
                            model.settings.locationEnabled
                                && !model.settings.backgroundPreciseLocationEnabled
                                ? "앱 사용 중만 기록 · ‘항상’ 위치 허용 필요"
                                : model.isSensorCollecting
                                    ? "기록 중 · \(model.settings.sensorCollectionProfile.intervalMinutes)분 간격 · 탭해서 경로 보기"
                                    : "장소와 이동수단 자동 추정"
                        )
                        .font(
                            .taption(size: SettingsTypography.rowSubtitle)
                        )
                        .foregroundStyle(Color.tpSecondary)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 2)

            Toggle(
                "",
                isOn: Binding(
                    get: { model.settings.locationEnabled },
                    set: { enabled in
                        Task {
                            if enabled {
                                await model.enableLocationCollection()
                            } else {
                                await model.disableLocationCollection()
                            }
                        }
                    }
                )
            )
            .labelsHidden()
            .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(red: 0.94, green: 0.94, blue: 0.95))
                .frame(height: 0.5)
        }
    }

    private func liveTrackingRow(_ session: TrackingSession) -> some View {
        let lastSample = model.latestSensorReading?.timestamp
        return HStack(spacing: 8) {
            Image(
                systemName: session.kind == .running
                    ? "figure.run"
                    : "figure.walk"
            )
            .font(.taption(size: 13, weight: .bold))
            .foregroundStyle(Color.tpTransitDark)
            .frame(width: 27, height: 27)
            .background(
                Color.tpTransit.opacity(0.28),
                in: RoundedRectangle(cornerRadius: 8)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    model.trackingSessionWasRecovered
                        ? "\(session.kind.displayName) 기록을 이어가는 중"
                        : "\(session.kind.displayName) 기록 중"
                )
                .font(.taption(size: SettingsTypography.rowTitle, weight: .bold))
                Text(
                    lastSample.map {
                        "마지막 위치 \(relativeAgeText($0)) · 경로 \(model.liveRouteState.readings.count)개"
                    } ?? "아직 첫 위치를 기다리는 중"
                )
                .font(.taption(size: SettingsTypography.rowSubtitle))
                .foregroundStyle(Color.tpSecondary)
            }

            Spacer(minLength: 4)
            Button("종료") {
                Task { await model.stopTracking() }
            }
            .font(.taption(size: SettingsTypography.action, weight: .bold))
            .buttonStyle(.borderedProminent)
            .tint(Color.tpTransitDark)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color.tpTransit.opacity(0.16),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func relativeAgeText(_ date: Date) -> String {
        let seconds = max(0, Int(Date.now.timeIntervalSince(date)))
        if seconds < 60 { return "방금" }
        return "\(seconds / 60)분 전"
    }

    /// 어느 빌드가 실제로 설치돼 있는지 앱 안에서 바로 확인할 수 있게 한다.
    /// 워치는 별도로 업데이트되므로 워치가 보고한 빌드도 함께 보여준다.
    private var versionFooter: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        let watchBuild = model.watchLaunchReport?.report
            .split(separator: "\n")
            .compactMap { line -> String? in
                let parts = line.split(separator: " ")
                guard parts.count >= 3, parts[1] == "build" else { return nil }
                return String(parts[2])
            }
            .last
        return VStack(alignment: .leading, spacing: 2) {
            Text("Taption Plan \(version) (빌드 \(build))")
            if let watchBuild, let reportedAt = model.watchLaunchReport?.receivedAt {
                // 워치가 마지막으로 보고한 값이다. 지금 설치된 빌드와 다를 수
                // 있어 언제 보고된 값인지 함께 보여준다.
                Text(
                    "Apple Watch 앱 빌드 \(watchBuild) · \(reportedAt, format: .dateTime.month().day().hour().minute()) 보고"
                )
            }
        }
        .font(.taption(size: SettingsTypography.footnote))
        .foregroundStyle(Color.tpSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 3)
        .textSelection(.enabled)
    }

    private var frequentPlacesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "star.circle.fill")
                    .font(.taption(size: 14))
                    .foregroundStyle(Color.tpPlaceDark)
                    .frame(width: 27, height: 27)
                    .background(
                        Color.tpPlace,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text("자주가는 곳")
                        .font(
                            .taption(
                                size: SettingsTypography.rowTitle,
                                weight: .bold
                            )
                        )
                        .foregroundStyle(Color.tpInk)
                    Text("집 · 학교 · 학원 · 회사 등을 현재 위치로 지정")
                        .font(.taption(size: SettingsTypography.rowSubtitle))
                        .foregroundStyle(Color.tpSecondary)
                }
                Spacer()
                Text(frequentPlacesSummary)
                    .font(
                        .taption(
                            size: SettingsTypography.value,
                            weight: .bold
                        )
                    )
                    .foregroundStyle(Color.tpPlaceDark)
            }

            if let suggestion = model.frequentPlaceSuggestion {
                suggestedPlaceCard(suggestion)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 6),
                    GridItem(.flexible(), spacing: 6),
                ],
                spacing: 6
            ) {
                ForEach(model.settings.frequentPlaces) { place in
                    frequentPlaceChip(place)
                }
            }

            HStack(spacing: 6) {
                TextField("사용자 추가", text: $customFrequentPlaceName)
                    .font(.taption(size: 9, weight: .semibold))
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        Color.tpBackground,
                        in: RoundedRectangle(cornerRadius: 9)
                    )

                Button {
                    model.addCustomFrequentPlace(name: customFrequentPlaceName)
                    customFrequentPlaceName = ""
                } label: {
                    Label("추가", systemImage: "plus")
                        .font(.taption(size: 8.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            Color.tpInk,
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                }
                .buttonStyle(.plain)
            }

            if !model.settings.floorCalibrationHistory.isEmpty {
                calibrationHistoryList
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(red: 0.94, green: 0.94, blue: 0.95))
                .frame(height: 0.5)
        }
        .sheet(item: $selectedFrequentPlace) { place in
            FrequentPlaceDetailView(model: model, placeID: place.id)
        }
        .confirmationDialog(
            "어떤 곳인가요?",
            isPresented: $showsSuggestedPlaceKinds,
            titleVisibility: .visible
        ) {
            ForEach(FrequentPlaceKind.allCases, id: \.self) { kind in
                Button(kind.defaultName) {
                    guard let placeID = model.registerFrequentPlaceSuggestion(
                        as: kind
                    ) else {
                        return
                    }
                    selectedFrequentPlace = model.settings.frequentPlaces
                        .first { $0.id == placeID }
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("위치는 이미 채워져 있습니다. 이름과 감지 범위는 다음 화면에서 고칠 수 있습니다.")
        }
    }

    private var userTransitLocationsRow: some View {
        settingsRow(
            icon: "tram.fill",
            iconBackground: Color.tpTransit.opacity(0.24),
            iconColor: Color.tpTransitDark,
            title: "사용자 등록 역·정류장",
            subtitle: "지하철역·버스정류장 이름과 유형 확인",
            value: "\(model.settings.userTransitLocations.count)개"
        ) {
            showsUserTransitLocations = true
        }
    }

    /// 등록되지 않은 자리를 한 번만 조용히 묻는다. "아니요"는 영구히 기억한다.
    private func suggestedPlaceCard(
        _ suggestion: FrequentPlaceSuggestion
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpPlaceDark)
                Text("자주 가는데 등록되지 않은 곳")
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                Spacer(minLength: 0)
            }

            Text(
                suggestion.suggestedName
                    ?? AppModel.coordinateLabel(suggestion.point)
            )
            .font(.taption(size: 9.5, weight: .bold))
            .foregroundStyle(Color.tpInk)
            .lineLimit(1)

            Text(suggestedPlaceSummary(suggestion))
                .font(.taption(size: 7.2, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(2)

            HStack(spacing: 6) {
                Button {
                    showsSuggestedPlaceKinds = true
                } label: {
                    Text("등록")
                        .font(.taption(size: 8.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Color.tpInk,
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    model.dismissFrequentPlaceSuggestion()
                } label: {
                    Text("아니요")
                        .font(.taption(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.tpBackground,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func suggestedPlaceSummary(
        _ suggestion: FrequentPlaceSuggestion
    ) -> String {
        let period = suggestion.reason == .weekly ? "최근 한 주" : "최근 한 달"
        let coordinates = AppModel.coordinateLabel(suggestion.point)
        guard suggestion.suggestedName != nil else {
            return "\(period)에 \(suggestion.visitCount)번 머물렀습니다."
        }
        return "\(period)에 \(suggestion.visitCount)번 머물렀습니다 · \(coordinates)"
    }

    private var calibrationHistoryList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("캘리브레이션 히스토리")
                .font(.taption(size: 9, weight: .bold))
                .foregroundStyle(Color.tpSecondary)
            ForEach(
                model.settings.floorCalibrationHistory.suffix(10).reversed()
            ) { event in
                HStack(spacing: 5) {
                    Image(
                        systemName: event.isAutomatic
                            ? "wand.and.stars"
                            : "hand.tap"
                    )
                    .font(.taption(size: 8))
                    .foregroundStyle(Color.tpPlaceDark)
                    Text("\(event.placeName) \(FloorLabel.korean(event.floor))")
                    .font(.taption(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                    Text(event.isAutomatic ? "자동" : "수동")
                        .font(.taption(size: 7.5))
                        .foregroundStyle(Color.tpSecondary)
                    Spacer(minLength: 4)
                    Text(
                        event.capturedAt,
                        format: .dateTime.month().day().hour().minute()
                    )
                    .font(.taption(size: 7.5))
                    .foregroundStyle(Color.tpSecondary)
                }
            }
        }
        .padding(.top, 3)
    }

    private var frequentPlacesSummary: String {
        let pinned = model.settings.frequentPlaces.filter {
            $0.point != nil
        }.count
        return "\(pinned)/\(model.settings.frequentPlaces.count)"
    }

    private func frequentPlaceChip(_ place: FrequentPlace) -> some View {
        Button {
            selectedFrequentPlace = place
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: place.kind.systemImage)
                        .font(.taption(size: 9, weight: .bold))
                        .foregroundStyle(Color.tpPlaceDark)
                    Text(place.name)
                        .font(.taption(size: 8.8, weight: .bold))
                        .foregroundStyle(Color.tpInk)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if place.point != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.taption(size: 8.8, weight: .bold))
                            .foregroundStyle(Color.tpPlaceDark)
                    }
                    Image(systemName: "chevron.right")
                        .font(.taption(size: 7.5, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                }

                Text(frequentPlaceSubtitle(place))
                    .font(.taption(size: 7.2, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .lineLimit(1)

                Text("탭하여 위치·감지 범위 설정")
                    .font(.taption(size: 6.8, weight: .medium))
                    .foregroundStyle(Color.tpSecondary.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.tpBackground,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func frequentPlaceSubtitle(_ place: FrequentPlace) -> String {
        guard place.point != nil else { return "미지정" }
        let floor = place.floor.map { " · \($0)층" } ?? ""
        return "지정됨\(floor) · 반경 \(Int(place.radiusMeters))m"
    }

    private var sensorCollectionProfileRow: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.taption(size: 14))
                    .foregroundStyle(Color.tpMovementDark)
                    .frame(width: 27, height: 27)
                    .background(
                        Color.tpMovement,
                        in: RoundedRectangle(cornerRadius: 8)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text("GPS · 센서 기록 간격")
                        .font(
                            .taption(
                                size: SettingsTypography.rowTitle,
                                weight: .bold
                            )
                        )
                        .foregroundStyle(Color.tpInk)
                    Text(
                        "\(model.settings.sensorCollectionProfile.intervalMinutes)분마다 "
                            + "\(Int(model.settings.sensorCollectionProfile.samplingWindowDuration))초만 수집 · 사이에는 센서 종료"
                    )
                        .font(
                            .taption(size: SettingsTypography.rowSubtitle)
                        )
                        .foregroundStyle(Color.tpSecondary)
                }

                Spacer(minLength: 4)

                Text(
                    "\(model.settings.sensorCollectionProfile.displayName) · "
                    + "\(model.settings.sensorCollectionProfile.intervalMinutes)분"
                )
                .font(
                    .taption(
                        size: SettingsTypography.value,
                        weight: .bold
                    )
                )
                .foregroundStyle(Color.tpMovementDark)
            }

            Slider(
                value: Binding(
                    get: {
                        Double(
                            model.settings.sensorCollectionProfile.rawValue
                        )
                    },
                    set: { value in
                        guard let profile = SensorCollectionProfile(
                            rawValue: Int(value.rounded())
                        ) else {
                            return
                        }
                        model.setSensorCollectionProfile(profile)
                    }
                ),
                in: 0...2,
                step: 1
            )
            .tint(Color.tpMovementDark)
            .accessibilityLabel("GPS와 센서 기록 간격")
            .accessibilityValue(
                "\(model.settings.sensorCollectionProfile.displayName), "
                + "\(model.settings.sensorCollectionProfile.intervalMinutes)분"
            )

            HStack(alignment: .top) {
                sensorProfileLabel("배터리 최소화", minutes: 15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                sensorProfileLabel("기본", minutes: 5)
                    .frame(maxWidth: .infinity)
                sensorProfileLabel("정확도 최적화", minutes: 1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(red: 0.94, green: 0.94, blue: 0.95))
                .frame(height: 0.5)
        }
    }

    private var watchAccelerationCollectionRow: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.taption(size: 14))
                    .foregroundStyle(Color.tpHealthDark)
                    .frame(width: 27, height: 27)
                    .background(
                        Color(red: 0.93, green: 0.96, blue: 0.91),
                        in: RoundedRectangle(cornerRadius: 8)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text("Apple Watch 가속도 수집")
                        .font(
                            .taption(
                                size: SettingsTypography.rowTitle,
                                weight: .bold
                            )
                        )
                        .foregroundStyle(Color.tpInk)
                    Text(
                        "iPhone 설정 자동 반영 · 워치는 가속도만 "
                            + model.settings.watchAccelerationProfile.subtitle
                    )
                        .font(.taption(size: SettingsTypography.rowSubtitle))
                        .foregroundStyle(Color.tpSecondary)
                }

                Spacer(minLength: 4)
                // CMSensorRecorder는 앱이 꺼져 있어도 시스템이 계속 기록하므로
                // 수집 간격이라는 개념이 없다. 켬·끔만 남긴다.
                Toggle(
                    "",
                    isOn: Binding(
                        get: {
                            model.settings.watchAccelerationProfile != .off
                        },
                        set: { enabled in
                            model.setWatchAccelerationProfile(
                                enabled ? .balanced : .off
                            )
                        }
                    )
                )
                .labelsHidden()
                .tint(Color.tpHealthDark)
                .accessibilityLabel("Apple Watch 가속도 수집")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(red: 0.94, green: 0.94, blue: 0.95))
                .frame(height: 0.5)
        }
    }

    private var watchDataSyncRow: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.taption(size: 14))
                    .foregroundStyle(Color.tpMovementDark)
                    .frame(width: 27, height: 27)
                    .background(
                        Color.tpMovement,
                        in: RoundedRectangle(cornerRadius: 8)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text("Apple Watch 데이터 가져오기")
                        .font(
                            .taption(
                                size: SettingsTypography.rowTitle,
                                weight: .bold
                            )
                        )
                        .foregroundStyle(Color.tpInk)
                    Text(model.settings.watchDataSyncProfile.subtitle)
                        .font(.taption(size: SettingsTypography.rowSubtitle))
                        .foregroundStyle(Color.tpSecondary)
                }

                Spacer(minLength: 4)
                Text(model.settings.watchDataSyncProfile.displayName)
                    .font(
                        .taption(
                            size: SettingsTypography.value,
                            weight: .bold
                        )
                    )
                    .foregroundStyle(Color.tpMovementDark)
            }

            Slider(
                value: Binding(
                    get: {
                        Double(model.settings.watchDataSyncProfile.rawValue)
                    },
                    set: { value in
                        guard let profile = TaptionWatchDataSyncProfile(
                            rawValue: Int(value.rounded())
                        ) else { return }
                        model.setWatchDataSyncProfile(profile)
                    }
                ),
                in: 0...3,
                step: 1
            )
            .tint(Color.tpMovementDark)
            .accessibilityLabel("Apple Watch 데이터 가져오기 간격")
            .accessibilityValue(model.settings.watchDataSyncProfile.subtitle)

            HStack {
                Text("iPhone 설정 자동 반영 · 건강·활동·가속도")
                    .font(.taption(size: SettingsTypography.footnote))
                    .foregroundStyle(Color.tpSecondary)
                Spacer()
                Button("지금 가져오기") {
                    model.requestWatchDataSync()
                }
                .font(.taption(size: SettingsTypography.footnote, weight: .bold))
                .foregroundStyle(Color.tpMovementDark)
            }

            HStack {
                watchProfileLabel("끔", alignment: .leading)
                watchProfileLabel("15분", alignment: .center)
                watchProfileLabel("5분", alignment: .center)
                watchProfileLabel("1분", alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(red: 0.94, green: 0.94, blue: 0.95))
                .frame(height: 0.5)
        }
    }

    private func watchProfileLabel(
        _ text: String,
        alignment: Alignment
    ) -> some View {
        Text(text)
            .font(.taption(size: SettingsTypography.footnote))
            .foregroundStyle(Color.tpSecondary)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func sensorProfileLabel(
        _ title: String,
        minutes: Int
    ) -> some View {
        VStack(
            alignment: minutes == 15
                ? .leading
                : (minutes == 1 ? .trailing : .center),
            spacing: 0
        ) {
            Text(title)
            Text("\(minutes)분")
                .fontWeight(.bold)
        }
        .font(.taption(size: SettingsTypography.footnote))
        .foregroundStyle(Color.tpSecondary)
    }

    private var accountCard: some View {
        Button {
            model.detail = .widgetPreview
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.taption(size: 19))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.tpInk, in: RoundedRectangle(cornerRadius: 12))

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
                    .font(.taption(size: 12, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }
            .padding(11)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                HStack(spacing: 7) {
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
                        .font(.taption(size: 8, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) 설정")
            .accessibilityValue(
                expandedSettingsSections.contains(title) ? "펼침" : "접힘"
            )

            if expandedSettingsSections.contains(title) {
                content()
            }
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.taption(size: 14))
                .foregroundStyle(iconColor)
                .frame(width: 27, height: 27)
                .background(
                    iconBackground,
                    in: RoundedRectangle(cornerRadius: 8)
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
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(red: 0.94, green: 0.94, blue: 0.95))
                .frame(height: 0.5)
        }
    }

    private func settingsRow(
        icon: String,
        iconBackground: Color = Color(red: 0.94, green: 0.94, blue: 0.95),
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
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.taption(size: 14))
                .foregroundStyle(iconColor)
                .frame(width: 27, height: 27)
                .background(
                    iconBackground,
                    in: RoundedRectangle(cornerRadius: 8)
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
                .font(.taption(size: 10, weight: .semibold))
                .foregroundStyle(
                    Color(red: 0.69, green: 0.69, blue: 0.71)
                )
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(red: 0.94, green: 0.94, blue: 0.95))
                .frame(height: 0.5)
        }
    }
}

private struct UserTransitLocationsSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    @State private var selectedLocation: UserTransitLocation?

    var body: some View {
        NavigationStack {
            List {
                if model.settings.userTransitLocations.isEmpty {
                    Text("등록된 역·정류장이 없습니다.")
                        .foregroundStyle(Color.tpSecondary)
                } else {
                    Section("등록된 위치") {
                        ForEach(model.settings.userTransitLocations) { location in
                            Button {
                                selectedLocation = location
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(location.name)
                                            .foregroundStyle(Color.tpInk)
                                        Text(location.kind.title)
                                            .font(.caption)
                                            .foregroundStyle(Color.tpSecondary)
                                    }
                                } icon: {
                                    Image(systemName: location.kind.systemImage)
                                        .foregroundStyle(Color.tpTransitDark)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("사용자 등록 위치")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .sheet(item: $selectedLocation) { location in
            UserTransitLocationNameEditor(model: model, location: location)
        }
    }
}

private struct UserTransitLocationNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let location: UserTransitLocation
    @State private var name: String

    init(model: AppModel, location: UserTransitLocation) {
        self.model = model
        self.location = location
        _name = State(initialValue: location.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(location.kind.title, systemImage: location.kind.systemImage)
                    TextField("이름", text: $name)
                } header: {
                    Text("등록된 위치 이름")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("이름 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        model.renameUserTransitLocation(location.id, name: name)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct FrequentPlaceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let placeID: UUID

    @State private var name = ""
    @State private var radiusMeters = 120.0
    @State private var floorPrompt = FloorCalibrationPrompt()
    @State private var minimumDwellMinutes = 10
    @State private var isAutomaticRecordingEnabled = true
    @State private var showsDeleteConfirmation = false
    @State private var referenceDeletionFloor: Int?
    @State private var calibrationTask: Task<Void, Never>?
    @State private var showsMapPicker = false

    private var place: FrequentPlace? {
        model.settings.frequentPlaces.first { $0.id == placeID }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if let place {
                        identitySection(place)
                        locationSection(place)
                        detectionSection
                        altitudeSection(place)
                        dangerSection(place)
                    } else {
                        ContentUnavailableView(
                            "장소를 찾을 수 없습니다",
                            systemImage: "mappin.slash"
                        )
                    }
                }
                .padding(16)
            }
            .background(Color.tpBackground.ignoresSafeArea())
            .navigationTitle("자주가는 곳 설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        model.updateFrequentPlaceDetails(
                            placeID,
                            name: name,
                            radiusMeters: radiusMeters,
                            minimumDwellMinutes: minimumDwellMinutes,
                            isAutomaticRecordingEnabled: isAutomaticRecordingEnabled
                        )
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .disabled(place == nil)
                }
            }
            .onAppear(perform: loadPlace)
            // 화면을 떠나면 재던 표본은 버린다. 절반만 잰 값으로 기준을
            // 남기지 않는다.
            .onDisappear {
                calibrationTask?.cancel()
                calibrationTask = nil
            }
            .confirmationDialog(
                "이 기준점을 지울까요?",
                isPresented: Binding(
                    get: { referenceDeletionFloor != nil },
                    set: { if !$0 { referenceDeletionFloor = nil } }
                ),
                presenting: referenceDeletionFloor
            ) { floor in
                Button(
                    "\(FloorLabel.korean(floor)) 기준 삭제",
                    role: .destructive
                ) {
                    model.deleteFrequentPlaceFloorReference(
                        placeID,
                        floor: floor
                    )
                    referenceDeletionFloor = nil
                }
                Button("취소", role: .cancel) { referenceDeletionFloor = nil }
            } message: { floor in
                Text("\(FloorLabel.korean(floor)) 기준점을 지웁니다. 이 장소의 위치와 다른 층 기준은 그대로 남습니다.")
            }
            .alert(
                "자주가는 곳 삭제",
                isPresented: $showsDeleteConfirmation
            ) {
                Button("취소", role: .cancel) {}
                Button("삭제", role: .destructive) {
                    model.deleteFrequentPlace(placeID)
                    dismiss()
                }
            } message: {
                Text("이 장소의 자동 위치·층수 기록 기준을 삭제합니다.")
            }
            .sheet(isPresented: $showsMapPicker) {
                FrequentPlaceMapPicker(
                    initialPoint: place?.point
                ) { coordinate in
                    model.setFrequentPlaceLocation(
                        placeID,
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    )
                }
            }
        }
    }

    private func loadPlace() {
        guard let place else { return }
        name = place.name
        radiusMeters = place.radiusMeters
        // 앱이 추정한 층은 미리 채우지 않는다. 고치려는 값이 기본값이 되면
        // 사용자는 틀린 층을 그대로 확인해 영구 기준으로 만든다.
        floorPrompt = FloorCalibrationPrompt(
            lastConfirmedFloor: model.lastManuallyConfirmedFloor(
                forPlaceID: placeID
            )
        )
        minimumDwellMinutes = place.minimumDwellMinutes
        isAutomaticRecordingEnabled = place.isAutomaticRecordingEnabled
    }

    private func identitySection(_ place: FrequentPlace) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label {
                Text("기본 정보")
                    .font(.taption(size: 12, weight: .bold))
            } icon: {
                Image(systemName: place.kind.systemImage)
                    .foregroundStyle(Color.tpPlaceDark)
            }

            TextField("장소 이름", text: $name)
                .font(.taption(size: 12, weight: .semibold))
                .textFieldStyle(.roundedBorder)

            Text("이름은 시간표의 위치 라벨과 위젯에 표시됩니다.")
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)
        }
        .detailCard()
    }

    private func locationSection(_ place: FrequentPlace) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label {
                Text("위치 기준")
                    .font(.taption(size: 12, weight: .bold))
            } icon: {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(Color.tpPlaceDark)
            }

            if let point = place.point {
                Text(
                    "위도 \(point.latitude, specifier: "%.5f") · 경도 \(point.longitude, specifier: "%.5f")"
                )
                .font(.taption(size: 10, weight: .semibold))
                .foregroundStyle(Color.tpInk)
            } else {
                Text("아직 현재 위치가 지정되지 않았습니다.")
                    .font(.taption(size: 10))
                    .foregroundStyle(Color.tpSecondary)
            }

            Button {
                model.setFrequentPlaceToCurrentLocation(placeID)
            } label: {
                Label(
                    place.point == nil ? "현재 위치로 지정" : "현재 위치로 다시 지정",
                    systemImage: "location.fill"
                )
                .font(.taption(size: 10, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .foregroundStyle(.white)
                .background(Color.tpPlaceDark, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)

            Button {
                showsMapPicker = true
            } label: {
                Label("지도에서 지정", systemImage: "map.fill")
                    .font(.taption(size: 10, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(Color.tpPlaceDark)
                    .background(
                        Color.tpPlace,
                        in: RoundedRectangle(cornerRadius: 9)
                    )
            }
            .buttonStyle(.plain)

            Text("이 자리를 장소의 기준점으로 삼습니다. 층수는 아래 '현재 층수'에서 알려 주면 되고, 머무는 동안의 고도 변화는 자동으로 따라갑니다.")
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)

            if place.point != nil {
                Button(role: .destructive) {
                    model.clearFrequentPlaceLocation(placeID)
                } label: {
                    Label("위치 기준 삭제", systemImage: "trash")
                        .font(.taption(size: 9, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
            }
        }
        .detailCard()
    }

    private var detectionSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label {
                Text("자동 감지 범위")
                    .font(.taption(size: 12, weight: .bold))
            } icon: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(Color.tpPlaceDark)
            }
            Toggle("자동 위치 기록", isOn: $isAutomaticRecordingEnabled)
                .font(.taption(size: 10, weight: .semibold))
                .tint(Color.tpPlaceDark)
            Text("끄면 이 장소는 자동 분석에서 제외되고 수동 지정만 유지됩니다.")
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)

            Divider()

            HStack {
                Text("반경")
                Spacer()
                Text("\(Int(radiusMeters.rounded()))m")
                    .fontWeight(.bold)
                    .foregroundStyle(Color.tpPlaceDark)
            }
            .font(.taption(size: 10))
            Slider(value: $radiusMeters, in: 30...500, step: 10)
                .tint(Color.tpPlaceDark)
            HStack {
                Text("30m · 건물 내부")
                Spacer()
                Text("500m · 넓은 구역")
            }
            .font(.taption(size: 8))
            .foregroundStyle(Color.tpSecondary)
            Text("GPS 오차와 건물 규모에 맞춰 위치로 인식할 범위를 정합니다.")
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)

            HStack {
                Text("최소 체류")
                Spacer()
                Text("\(minimumDwellMinutes)분")
                    .fontWeight(.bold)
                    .foregroundStyle(Color.tpPlaceDark)
            }
            .font(.taption(size: 10))
            Slider(
                value: Binding(
                    get: { Double(minimumDwellMinutes) },
                    set: { minimumDwellMinutes = Int($0.rounded()) }
                ),
                in: 5...120,
                step: 5
            )
            .tint(Color.tpPlaceDark)
            Text("이 시간보다 짧은 방문은 일반 장소로 남깁니다.")
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)
        }
        .detailCard()
    }

    private var sampling: FloorCalibrationSampling? {
        guard let sampling = model.floorCalibrationSampling,
              sampling.placeID == placeID else {
            return nil
        }
        return sampling
    }

    private func altitudeSection(_ place: FrequentPlace) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label {
                Text("현재 층수")
                    .font(.taption(size: 12, weight: .bold))
            } icon: {
                Image(systemName: "building.2.crop.circle")
                    .foregroundStyle(Color.tpPlaceDark)
            }
            Stepper(
                value: Binding(
                    get: { floorPrompt.floor },
                    set: { floorPrompt.select($0) }
                ),
                in: FloorCalibrationPrompt.range
            ) {
                HStack {
                    Text("지금 있는 층")
                    Spacer()
                    Text(FloorLabel.korean(floorPrompt.floor))
                        .fontWeight(.bold)
                        .foregroundStyle(Color.tpPlaceDark)
                }
                .font(.taption(size: 10))
            }
            .tint(Color.tpPlaceDark)
            .disabled(sampling != nil)

            calibrateButton

            Text(calibrationGuidance)
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)

            Divider()

            if !place.floorReferencePoints.isEmpty {
                floorReferenceList(place)
            }
            if place.floorReferencePoints.count > 1 {
                Text(
                    "이 건물 층 높이 · \(place.floorHeightMeters, specifier: "%.1f")m · 기준 \(place.floorReferencePoints.count)개 층"
                )
            }
            if let reading = model.latestSensorReading,
               let relative = reading.relativeAltitudeMeters {
                Text("현재 센서 · 상대고도 \(relative, specifier: "%.1f")m")
            }
            if let estimate = model.latestAltitudeEstimate {
                Text(
                    "현재 추정 · \(estimate.floor)층 · 해발 "
                        + "\(Int(estimate.seaLevelAltitudeMeters.rounded()))m"
                )
                .fontWeight(.semibold)
                .foregroundStyle(Color.tpPlaceDark)
            } else if place.point == nil {
                Text("현재 위치를 지정하면 이 장소의 층 추정이 시작됩니다.")
            }
        }
        .font(.taption(size: 9))
        .foregroundStyle(Color.tpSecondary)
        .detailCard()
    }

    /// 한 번 눌러 값을 확인하고, 다시 눌러야 잰다. 미리 채워 둔 값을 한 번에
    /// 확정할 수 있으면 고치려던 층이 그대로 기준으로 굳는다.
    private var calibrateButton: some View {
        Button {
            if floorPrompt.canCommit {
                let floor = floorPrompt.floor
                floorPrompt.disarm()
                calibrationTask = Task {
                    await model.calibrateFrequentPlaceFloor(
                        placeID,
                        floor: floor
                    )
                }
            } else {
                floorPrompt.arm()
            }
        } label: {
            Group {
                if let sampling {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                        Text("재는 중 · \(sampling.collected)/\(sampling.target)")
                    }
                } else if floorPrompt.canCommit {
                    Label(
                        "\(FloorLabel.korean(floorPrompt.floor)) 맞습니다 · 다시 눌러 보정",
                        systemImage: "checkmark.circle.fill"
                    )
                } else {
                    Label("이 층으로 보정", systemImage: "building.2.fill")
                }
            }
            .font(.taption(size: 10, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .foregroundStyle(.white)
            .background(
                floorPrompt.canCommit ? Color.tpInk : Color.tpPlaceDark,
                in: RoundedRectangle(cornerRadius: 9)
            )
        }
        .buttonStyle(.plain)
        .disabled(sampling != nil)
    }

    private var calibrationGuidance: String {
        if sampling != nil {
            return "한자리에 선 채로 기다려 주세요. 다 재기 전에는 아무것도 기록되지 않습니다."
        }
        if floorPrompt.canCommit {
            return "다시 누르면 약 12초 동안 기압을 재서 이 층을 이 건물의 기준으로 남깁니다."
        }
        return "지금 있는 층을 맞춘 뒤 누르세요. 한 번 더 눌러 확인해야 기록합니다. 층 높이는 서로 다른 층에서 두 번 이상 알려 줄 때 그 차이로 앱이 스스로 맞춥니다."
    }

    private func floorReferenceList(_ place: FrequentPlace) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("이 건물 층 기준")
                .font(.taption(size: 9, weight: .bold))
                .foregroundStyle(Color.tpSecondary)
            ForEach(place.floorReferencePoints, id: \.floor) { reference in
                HStack(spacing: 6) {
                    Text(FloorLabel.korean(reference.floor))
                        .font(.taption(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.tpInk)
                    Text(reference.isManual ? "직접 확인" : "자동")
                        .font(.taption(size: 8))
                    Spacer(minLength: 4)
                    Text(
                        reference.capturedAt,
                        format: .dateTime.month().day().hour().minute()
                    )
                    .font(.taption(size: 8))
                    Button {
                        referenceDeletionFloor = reference.floor
                    } label: {
                        Image(systemName: "trash")
                            .font(.taption(size: 9, weight: .semibold))
                            .foregroundStyle(Color(red: 0.78, green: 0.24, blue: 0.24))
                            .padding(.leading, 4)
                            .frame(minWidth: 30, minHeight: 30)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("틀린 기준점은 지울 수 있습니다. 나머지 기준과 이 장소의 위치는 그대로 남습니다.")
                .font(.taption(size: 8.5))
        }
    }

    private func dangerSection(_ place: FrequentPlace) -> some View {
        Group {
            if place.kind == .custom {
                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Label("자주가는 곳 삭제", systemImage: "trash")
                        .font(.taption(size: 10, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .background(
                    Color(red: 1, green: 0.93, blue: 0.93),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
        }
    }

}

private struct FrequentPlaceMapPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cameraPosition: MapCameraPosition
    @State private var selectedCoordinate: CLLocationCoordinate2D?

    let onSave: (CLLocationCoordinate2D) -> Void

    init(
        initialPoint: GeoPoint?,
        onSave: @escaping (CLLocationCoordinate2D) -> Void
    ) {
        let coordinate = CLLocationCoordinate2D(
            latitude: initialPoint?.latitude ?? 37.5665,
            longitude: initialPoint?.longitude ?? 126.9780
        )
        _cameraPosition = State(
            initialValue: .region(
                MKCoordinateRegion(
                    center: coordinate,
                    latitudinalMeters: 1_200,
                    longitudinalMeters: 1_200
                )
            )
        )
        _selectedCoordinate = State(
            initialValue: initialPoint == nil ? nil : coordinate
        )
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $cameraPosition) {
                    if let selectedCoordinate {
                        Marker("선택한 위치", coordinate: selectedCoordinate)
                            .tint(Color.tpPlaceDark)
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .onTapGesture { point in
                    selectedCoordinate = proxy.convert(point, from: .local)
                }
            }
            .overlay(alignment: .bottom) {
                Text("지도를 탭해 장소의 기준점을 선택하세요.")
                    .font(.taption(size: 10, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 18)
            }
            .navigationTitle("지도에서 지정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        guard let selectedCoordinate else { return }
                        onSave(selectedCoordinate)
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .disabled(selectedCoordinate == nil)
                }
            }
        }
    }
}

private extension View {
    func detailCard() -> some View {
        self
            .padding(13)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
