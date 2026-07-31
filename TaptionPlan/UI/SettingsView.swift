import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var sharedExport: ShareableURL?
    @State private var showsDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            DraftTopBar(title: "설정", trailing: model.integrationStatusSummary)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 9) {
                    accountCard
                    proCard

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
                            subtitle: "고정 일정 가져오기",
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
                            subtitle: "운동 · 수면 실제 기록",
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
                        .font(.system(size: 7))
                        .foregroundStyle(Color.tpSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 3)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
            }
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
                        .font(.system(size: 14))
                        .foregroundStyle(Color.tpPlaceDark)
                        .frame(width: 27, height: 27)
                        .background(
                            Color.tpPlace,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            Text("위치 · 이동")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Color.tpInk)
                            if model.settings.locationEnabled {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 6.5, weight: .bold))
                                    .foregroundStyle(Color.tpSecondary)
                            }
                        }
                        Text(
                            model.isSensorCollecting
                                ? "기록 중 · 탭해서 경로 보기"
                                : "장소와 이동수단 자동 추정"
                        )
                        .font(.system(size: 6.8))
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

    private var accountCard: some View {
        Button {
            model.detail = .widgetPreview
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 19))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.tpInk, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 2) {
                    Text("내 시간표")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.tpInk)
                    Text("iPhone · Apple Watch · iCloud")
                        .font(.system(size: 7.5))
                        .foregroundStyle(Color.tpSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
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
                    .font(.system(size: 18, weight: .semibold))
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
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color.tpInk)
                    Text(model.storeStatusMessage)
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                    Text("한 번 구매하면 이후 가격이 올라도 계속 사용할 수 있습니다.")
                        .font(.system(size: 6.8))
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
                        .font(.system(size: 8.5, weight: .bold))
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
                        .font(.system(size: 8.5, weight: .bold))
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
                .font(.system(size: 7.5, weight: .black))
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
                .font(.system(size: 14))
                .foregroundStyle(iconColor)
                .frame(width: 27, height: 27)
                .background(
                    iconBackground,
                    in: RoundedRectangle(cornerRadius: 8)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text(subtitle)
                    .font(.system(size: 6.8))
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
                .font(.system(size: 14))
                .foregroundStyle(iconColor)
                .frame(width: 27, height: 27)
                .background(
                    iconBackground,
                    in: RoundedRectangle(cornerRadius: 8)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text(subtitle)
                    .font(.system(size: 6.8))
                    .foregroundStyle(Color.tpSecondary)
            }

            Spacer(minLength: 4)

            if !value.isEmpty {
                Text(value)
                    .font(
                        .system(
                            size: 8,
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
                .font(.system(size: 10, weight: .semibold))
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
