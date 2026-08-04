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
                    proCard

                    settingsSection(
                        "나에게 맞추기",
                        summary: "\(model.snapshot.categories.count)개 대분류"
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
                        summary: "현재 \(TimeScale(timelineLevel: model.settings.startScale).rawValue)"
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
                            subtitle: "일·주·월·년의 마지막 선택 유지",
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
                            icon: "square.grid.2x2",
                            title: "대분류 관리",
                            subtitle: "이름 · 아이콘 · 색상 · 순서 · 숨김",
                            value: "\(model.snapshot.categories.count)개"
                        ) {
                            model.detail = .categoryManager
                        }
                        frequentPlacesRow
                    }

                    settingsSection(
                        "앱 연동",
                        summary: model.integrationStatusSummary
                    ) {
                        settingsToggleRow(
                            icon: "photo",
                            iconBackground: .tpPhoto,
                            iconColor: .tpPhotoDark,
                            title: "사진",
                            subtitle: "촬영 시각에 타임라인 표시",
                            isOn: Binding(
                                get: {
                                    model.settings.showsPhotos
                                        && model.permissionState(
                                            for: .photos
                                        ).isGranted
                                },
                                set: { enabled in
                                    Task {
                                        await model.setPhotosEnabled(enabled)
                                    }
                                }
                            )
                        )
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
                        appUsageRow
                        locationIntegrationRow
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
                        settingsRow(
                            icon: "icloud",
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
                            title: "iCloud 동기화",
                            subtitle: "계획·분류·메모를 내 기기 사이에 보관",
                            value: cloudStatus,
                            valueIsOn: model.permissionState(
                                for: .cloud
                            ).isGranted
                        ) {
                            Task {
                                await model.synchronizeCloud()
                            }
                        }
                    }

                    settingsSection(
                        "데이터와 개인정보",
                        summary: "기기 안에 안전하게 저장"
                    ) {
                        settingsToggleRow(
                            icon: "lock.shield",
                            title: "위젯 개인정보",
                            subtitle: "켜면 위젯에 계획 제목을 표시",
                            isOn: Binding(
                                get: {
                                    model.settings.showsPhotosInWidgets
                                },
                                set: { value in
                                    model.setWidgetPhotosVisible(value)
                                }
                            )
                        )
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
                }
                .padding(.horizontal, 13)
                .padding(.top, 11)
                .padding(.bottom, 104)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.always)
            .background(Color.tpBackground)
        }
        .onAppear {
            model.refreshAppleWatchConnectionState()
            model.refreshAppUsageAuthorizationState()
        }
        .overlay {
            if model.isRefreshingIntegrations
                || model.isCloudSyncing
                || model.isStoreLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(12)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .sheet(item: $sharedExport) { value in
            ActivityShareSheet(items: [value.url])
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

    private var cloudStatus: String {
        if model.isCloudSyncing { return "동기화 중" }
        return model.permissionState(for: .cloud).settingsLabel
    }

    private var watchInstallRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            settingsRow(
                icon: "applewatch",
                iconBackground: Color(red: 0.91, green: 0.92, blue: 0.95),
                iconColor: Color.tpInk,
                title: "Apple Watch 앱",
                subtitle: model.appleWatchConnectionState.settingsLabel,
                value: "설치 확인"
            ) {
                model.refreshAppleWatchConnectionState()
            }
            if model.appleWatchConnectionState == .appNotInstalled {
                Text("iPhone의 Watch 앱 → 나의 시계 → 사용 가능한 앱 → Taption Plan에서 설치")
                    .font(.taption(size: SettingsTypography.footnote))
                    .foregroundStyle(Color.tpSecondary)
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

    private var appUsageRow: some View {
        settingsRow(
            icon: "app.badge.clock",
            iconBackground: Color(red: 0.93, green: 0.90, blue: 0.98),
            iconColor: Color(red: 0.42, green: 0.34, blue: 0.64),
            title: "앱 사용시간",
            subtitle: "Screen Time 시간대별 사용 기록",
            value: model.appUsageStatusText
        ) {
            Task { await model.requestAppUsageAuthorization() }
        }
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
                            Text("위치 · 이동")
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
                    Text(
                        "\(event.placeName) \(event.floor < 0 ? "지하 \(-event.floor)층" : "\(event.floor)층")"
                    )
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

                Text("탭하여 위치·층수·감지 범위 설정")
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
                        "워치는 가속도만 "
                            + model.settings.watchAccelerationProfile.subtitle
                    )
                        .font(.taption(size: SettingsTypography.rowSubtitle))
                        .foregroundStyle(Color.tpSecondary)
                }

                Spacer(minLength: 4)
                Text(model.settings.watchAccelerationProfile.displayName)
                    .font(
                        .taption(
                            size: SettingsTypography.value,
                            weight: .bold
                        )
                    )
                    .foregroundStyle(Color.tpHealthDark)
            }

            Slider(
                value: Binding(
                    get: {
                        Double(model.settings.watchAccelerationProfile.rawValue)
                    },
                    set: { value in
                        guard let profile = TaptionWatchAccelerationProfile(
                            rawValue: Int(value.rounded())
                        ) else { return }
                        model.setWatchAccelerationProfile(profile)
                    }
                ),
                in: 0...3,
                step: 1
            )
            .tint(Color.tpHealthDark)
            .accessibilityLabel("Apple Watch 가속도 수집 간격")
            .accessibilityValue(
                model.settings.watchAccelerationProfile.subtitle
            )

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
                Text("건강·활동·가속도 최신값")
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

    private var proCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: model.hasProAccess
                    ? "checkmark.seal.fill"
                    : "sparkles")
                    .font(.taption(size: 18, weight: .semibold))
                    .foregroundStyle(
                        model.hasProAccess
                            ? Color(red: 0.18, green: 0.52, blue: 0.32)
                            : Color(red: 0.57, green: 0.38, blue: 0.08)
                    )
                    .frame(width: 35, height: 35)
                    .background(
                        model.hasProAccess
                            ? Color(red: 0.90, green: 0.97, blue: 0.92)
                            : Color(red: 1.00, green: 0.95, blue: 0.85),
                        in: RoundedRectangle(cornerRadius: 11)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.proProduct?.displayName ?? "Taption Plan Pro")
                        .font(
                            .taption(
                                size: SettingsTypography.cardTitle,
                                weight: .black
                            )
                        )
                        .foregroundStyle(Color.tpInk)
                    Text(model.storeStatusMessage)
                        .font(
                            .taption(
                                size: SettingsTypography.accountSubtitle,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(Color.tpSecondary)
                    Text("한 번 구매하면 이후 가격이 올라도 계속 사용할 수 있습니다.")
                        .font(
                            .taption(size: SettingsTypography.rowSubtitle)
                        )
                        .foregroundStyle(Color.tpSecondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                Button {
                    Task {
                        if model.proProduct == nil {
                            await model.refreshStore()
                        } else {
                            await model.purchasePro()
                        }
                    }
                } label: {
                    Text(primaryPurchaseLabel)
                        .font(
                            .taption(
                                size: SettingsTypography.action,
                                weight: .bold
                            )
                        )
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            model.hasProAccess
                                ? Color(red: 0.18, green: 0.52, blue: 0.32)
                                : Color.tpInk,
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                }
                .buttonStyle(.plain)
                .disabled(model.hasProAccess || model.isStoreLoading)

                Button {
                    Task { await model.restorePurchases() }
                } label: {
                    Text("구매 복원")
                        .font(
                            .taption(
                                size: SettingsTypography.action,
                                weight: .bold
                            )
                        )
                        .foregroundStyle(Color.tpInk)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Color.tpBackground,
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                }
                .buttonStyle(.plain)
                .disabled(model.isStoreLoading)
            }
        }
        .padding(11)
        .background(
            Color.white,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private var primaryPurchaseLabel: String {
        if model.hasProAccess { return "구매 완료" }
        if let product = model.proProduct {
            return "\(product.displayPrice) 영구 구매"
        }
        return "구매 정보 다시 확인"
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
            ForEach(TimeScale.allCases) { scale in
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

private struct FrequentPlaceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let placeID: UUID

    @State private var name = ""
    @State private var radiusMeters = 120.0
    @State private var floorHeightMeters = 3.0
    @State private var minimumDwellMinutes = 10
    @State private var isAutomaticRecordingEnabled = true
    @State private var selectedFloor = 1
    @State private var showsFloorPicker = false
    @State private var addsCalibrationPoint = false
    @State private var showsDeleteConfirmation = false

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
                            floorHeightMeters: floorHeightMeters,
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
            .sheet(isPresented: $showsFloorPicker) {
                floorPicker
                    .presentationDetents([.height(320)])
                    .presentationDragIndicator(.visible)
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
        }
    }

    private func loadPlace() {
        guard let place else { return }
        name = place.name
        radiusMeters = place.radiusMeters
        floorHeightMeters = place.floorHeightMeters
        minimumDwellMinutes = place.minimumDwellMinutes
        isAutomaticRecordingEnabled = place.isAutomaticRecordingEnabled
        selectedFloor = place.floor ?? 1
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
                Text("위치·층수 기준")
                    .font(.taption(size: 12, weight: .bold))
            } icon: {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(Color.tpPlaceDark)
            }

            if let point = place.point {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        "위도 \(point.latitude, specifier: "%.5f") · 경도 \(point.longitude, specifier: "%.5f")"
                    )
                    .font(.taption(size: 10, weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                    Text(
                        place.floor.map { "기준 \($0)층" } ?? "층수 미지정"
                    )
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
                }
            } else {
                Text("아직 현재 위치가 지정되지 않았습니다.")
                    .font(.taption(size: 10))
                    .foregroundStyle(Color.tpSecondary)
            }

            Button {
                selectedFloor = place.floor ?? 1
                addsCalibrationPoint = false
                showsFloorPicker = true
            } label: {
                Label(
                    place.point == nil ? "현재 위치와 층수 지정" : "현재 위치로 재보정",
                    systemImage: "location.fill"
                )
                .font(.taption(size: 10, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .foregroundStyle(.white)
                .background(Color.tpPlaceDark, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)

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

    private func altitudeSection(_ place: FrequentPlace) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label {
                Text("고도·층수 보정")
                    .font(.taption(size: 12, weight: .bold))
            } icon: {
                Image(systemName: "building.2.crop.circle")
                    .foregroundStyle(Color.tpPlaceDark)
            }
            HStack {
                Text("층 높이")
                Spacer()
                Text("\(floorHeightMeters, specifier: "%.1f")m")
                    .fontWeight(.bold)
                    .foregroundStyle(Color.tpPlaceDark)
            }
            .font(.taption(size: 10))
            Slider(value: $floorHeightMeters, in: 2.2...5.0, step: 0.1)
                .tint(Color.tpPlaceDark)
            Text("기압·상대고도 차이를 이 층 높이로 나눠 같은 건물의 층을 추정합니다.")
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)

            Divider()

            if let relative = place.referenceRelativeAltitudeMeters {
                Text("기준 상대고도 \(relative, specifier: "%.1f")m")
            }
            if let pressure = place.referencePressureKilopascals {
                Text("기준 기압 \(pressure, specifier: "%.2f")kPa")
            }
            if let capturedAt = place.floorCapturedAt {
                Text(
                    "마지막 보정 \(capturedAt, format: .dateTime.month().day().hour().minute())"
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
            }
            if !place.floorReferencePoints.isEmpty {
                let references = place.floorReferencePoints
                Text("저장된 층 기준")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.tpInk)
                ForEach(
                    references.sorted { $0.floor < $1.floor },
                    id: \.floor
                ) { reference in
                    Text(
                        reference.floor < 0
                            ? "지하 \(-reference.floor)층 · \(reference.capturedAt, format: .dateTime.month().day().hour().minute())"
                            : "\(reference.floor)층 · \(reference.capturedAt, format: .dateTime.month().day().hour().minute())"
                    )
                }
            }
            Button {
                selectedFloor = model.latestAltitudeEstimate?.floor
                    ?? place.floor
                    ?? 1
                addsCalibrationPoint = true
                showsFloorPicker = true
            } label: {
                Label("현재 고도를 다른 층으로 보정", systemImage: "plus.circle")
                    .font(.taption(size: 9, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            if place.referenceRelativeAltitudeMeters == nil,
               place.referencePressureKilopascals == nil {
                Text("위치와 층수를 지정하면 기압·고도 기준이 함께 저장됩니다.")
            }
        }
        .font(.taption(size: 9))
        .foregroundStyle(Color.tpSecondary)
        .detailCard()
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

    private var floorPicker: some View {
        VStack(spacing: 12) {
            Text(addsCalibrationPoint ? "추가 층 기준 저장" : "기준 층 선택")
                .font(.taption(size: 15, weight: .bold))
                .foregroundStyle(Color.tpInk)
            Text(
                addsCalibrationPoint
                    ? "같은 건물의 현재 층을 추가해 고도 보정을 정확하게 합니다."
                    : "현재 위치의 층을 기준으로 저장합니다."
            )
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)
            Picker("층수", selection: $selectedFloor) {
                ForEach(Array(-20 ... -1) + Array(1 ... 200), id: \.self) { floor in
                    Text(floor < 0 ? "지하 \(-floor)층" : "\(floor)층")
                        .tag(floor)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 140)
            Button("현재 위치로 저장") {
                if addsCalibrationPoint {
                    model.addFrequentPlaceFloorCalibration(
                        placeID,
                        floor: selectedFloor
                    )
                } else {
                    model.setFrequentPlaceToCurrentLocation(
                        placeID,
                        floor: selectedFloor
                    )
                }
                showsFloorPicker = false
            }
            .buttonStyle(.borderedProminent)
            .font(.taption(size: 10, weight: .bold))
        }
        .padding(18)
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
        case .year: self = .year
        }
    }
}

#Preview {
    SettingsView(model: AppModel())
}
