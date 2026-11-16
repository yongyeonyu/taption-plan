import MapKit
import SwiftUI

extension SettingsView {
    var cloudSyncRow: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
            settingsRow(
                icon: "icloud",
                iconBackground: Color(red: 0.90, green: 0.95, blue: 1.00),
                iconColor: Color(red: 0.16, green: 0.45, blue: 0.75),
                title: "iCloud 동기화",
                subtitle: "계획·분류·메모를 내 기기 사이에 보관",
                value: model.cloudStatusText,
                valueIsOn: model.permissionState(for: .cloud).isGranted
            ) {
                model.startManualCloudSync()
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

    var watchInstallRow: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
            settingsRow(
                icon: "applewatch",
                iconBackground: Color(red: 0.91, green: 0.92, blue: 0.95),
                iconColor: Color.tpInk,
                title: "Apple Watch 건강 데이터",
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
        }
    }

    var locationIntegrationRow: some View {
        HStack(spacing: TaptionMenuMetrics.sectionSpacing) {
            Button {
                guard model.settings.locationEnabled else { return }
                model.selectedTab = .schedule
                model.detail = .locationTimeline
            } label: {
                HStack(spacing: TaptionMenuMetrics.sectionSpacing) {
                    Image(systemName: "mappin.and.ellipse")
                        .accessibilityHidden(true)
                        .font(.taption(size: 13))
                        .foregroundStyle(Color.tpPlaceDark)
                        .frame(width: 24, height: 24)
                        .background(
                            Color.tpPlace,
                            in: RoundedRectangle(cornerRadius: TaptionRadius.tight)
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
                                    ? "기록 중 · \(GPSLoggingPreferences.intervalText(model.settings.gpsLoggingPreferences.intervalSeconds)) 간격 · 탭해서 경로 보기"
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
        .padding(.horizontal, 9)
        .frame(minHeight: 44)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.tpControlFill)
                .frame(height: 0.5)
        }
    }

    func liveTrackingRow(_ session: TrackingSession) -> some View {
        let lastSample = model.latestSensorReading?.timestamp
        return HStack(spacing: TaptionMenuMetrics.sectionSpacing) {
            Image(
                systemName: session.kind == .running
                    ? "figure.run"
                    : "figure.walk"
            )
            .accessibilityHidden(true)
            .font(.taption(size: 13, weight: .bold))
            .foregroundStyle(Color.tpTransitDark)
            .frame(width: 24, height: 24)
            .background(
                Color.tpTransit.opacity(0.28),
                in: RoundedRectangle(cornerRadius: TaptionRadius.tight)
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
        .padding(.vertical, 7)
        .background(
            Color.tpTransit.opacity(0.16),
            in: RoundedRectangle(cornerRadius: TaptionRadius.panel, style: .continuous)
        )
    }

    private func relativeAgeText(_ date: Date) -> String {
        let seconds = max(0, Int(Date.now.timeIntervalSince(date)))
        if seconds < 60 { return "방금" }
        return "\(seconds / 60)분 전"
    }

    /// 어느 빌드가 실제로 설치돼 있는지 앱 안에서 바로 확인할 수 있게 한다.
    /// 워치는 별도로 업데이트되므로 워치가 보고한 빌드도 함께 보여준다.
    var versionFooter: some View {
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
            Text("BOKKI Plan \(version) (빌드 \(build))")
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

    var watchAccelerationCollectionRow: some View {
        VStack(spacing: TaptionSpacing.cozy) {
            HStack(spacing: TaptionMenuMetrics.sectionSpacing) {
                Image(systemName: "waveform.path.ecg")
                    .accessibilityHidden(true)
                    .font(.taption(size: 13))
                    .foregroundStyle(Color.tpHealthDark)
                    .frame(width: 24, height: 24)
                    .background(
                        Color.tpSuccessTint,
                        in: RoundedRectangle(cornerRadius: TaptionRadius.tight)
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
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.tpControlFill)
                .frame(height: 0.5)
        }
    }

    var watchDataSyncRow: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.cozy) {
            Text("Apple Watch 데이터 가져오기")
                .font(.taption(size: SettingsTypography.rowTitle, weight: .bold))
            Text("앱을 열면 바로 조회 · 건강·운동·수면")
                .font(.taption(size: SettingsTypography.rowSubtitle))
                .foregroundStyle(Color.tpSecondary)
            Text(model.appleWatchCompanionRow.subtitle)
                .font(.taption(size: SettingsTypography.footnote))
                .foregroundStyle(Color.tpSecondary)
            Button { model.requestWatchDataSync() } label: {
                Text("지금 가져오기").frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .disabled(!model.settings.healthEnabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
