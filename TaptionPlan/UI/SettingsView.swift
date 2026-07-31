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
    @State private var floorPromptPlace: FrequentPlace?
    @State private var frequentPlaceFloor = 1

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

                    settingsSection("나에게 맞추기") {
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
                            subtitle: "역할 · 상황 · 목표와 추천 대분류 설정",
                            value: model.currentProfileDisplayName
                        ) {
                            model.openInitialSetup()
                        }
                    }

                    settingsSection("화면과 동작") {
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
                    }

                    settingsSection("앱 연동") {
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
                        locationIntegrationRow
                        frequentPlacesRow
                        sensorCollectionProfileRow
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
                    }

                    settingsSection("데이터와 개인정보") {
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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(red: 0.94, green: 0.94, blue: 0.95))
                .frame(height: 0.5)
        }
        .sheet(item: $floorPromptPlace) { place in
            frequentPlaceFloorPicker(place)
                .presentationDetents([.height(310)])
                .presentationDragIndicator(.visible)
        }
    }

    private var frequentPlacesSummary: String {
        let pinned = model.settings.frequentPlaces.filter {
            $0.point != nil
        }.count
        return "\(pinned)/\(model.settings.frequentPlaces.count)"
    }

    private func frequentPlaceChip(_ place: FrequentPlace) -> some View {
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
            }

            Text(frequentPlaceSubtitle(place))
                .font(.taption(size: 7.2, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(1)

            HStack(spacing: 4) {
                Button {
                    frequentPlaceFloor = place.floor ?? 1
                    floorPromptPlace = place
                } label: {
                    Text("현재 위치 설정")
                        .font(.taption(size: 7.5, weight: .bold))
                        .foregroundStyle(Color.tpPlaceDark)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            Color.tpPlace,
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    model.clearFrequentPlaceLocation(place.id)
                } label: {
                    Text("위치 삭제")
                        .font(.taption(size: 7.5, weight: .bold))
                        .foregroundStyle(
                            place.point == nil
                                ? Color.tpSecondary.opacity(0.45)
                                : Color(red: 0.72, green: 0.19, blue: 0.16)
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            place.point == nil
                                ? Color.tpBackground
                                : Color(red: 1.00, green: 0.92, blue: 0.92),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                }
                .buttonStyle(.plain)
                .disabled(place.point == nil)

                if place.kind == .custom {
                    Button(role: .destructive) {
                        model.deleteFrequentPlace(place.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.taption(size: 8, weight: .bold))
                            .foregroundStyle(
                                Color(red: 0.72, green: 0.19, blue: 0.16)
                            )
                            .frame(width: 24, height: 23)
                            .background(
                                Color(red: 1.00, green: 0.92, blue: 0.92),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(8)
        .background(
            Color.tpBackground,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func frequentPlaceSubtitle(_ place: FrequentPlace) -> String {
        guard place.point != nil else { return "미지정" }
        let floor = place.floor.map { " · \($0)층" } ?? ""
        return "지정됨\(floor) · 반경 \(Int(place.radiusMeters))m"
    }

    private func frequentPlaceFloorPicker(
        _ place: FrequentPlace
    ) -> some View {
        VStack(spacing: 12) {
            Text("\(place.name) 현재 층")
                .font(.taption(size: 15, weight: .bold))
                .foregroundStyle(Color.tpInk)

            Text("기준 층을 선택하면 같은 건물 안의 층간 이동을 센서로 구분합니다.")
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)
                .multilineTextAlignment(.center)

            Picker("층수", selection: $frequentPlaceFloor) {
                ForEach(frequentPlaceFloorOptions, id: \.self) { floor in
                    Text(floorName(floor)).tag(floor)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 120)

            HStack(spacing: 8) {
                Button("취소") {
                    floorPromptPlace = nil
                }
                .buttonStyle(.bordered)

                Button("현재 위치로 설정") {
                    floorPromptPlace = nil
                    model.setFrequentPlaceToCurrentLocation(
                        place.id,
                        floor: frequentPlaceFloor
                    )
                }
                .buttonStyle(.borderedProminent)
            }
            .font(.taption(size: 10, weight: .bold))
        }
        .padding(18)
    }

    private var frequentPlaceFloorOptions: [Int] {
        Array(-20 ... -1) + Array(1 ... 200)
    }

    private func floorName(_ floor: Int) -> String {
        floor < 0 ? "지하 \(-floor)층" : "\(floor)층"
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
                    Text("변경하면 위치·동작 수집에 바로 적용")
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
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(
                    .taption(
                        size: SettingsTypography.sectionTitle,
                        weight: .black
                    )
                )
                .foregroundStyle(Color.tpSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 5)
            content()
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
