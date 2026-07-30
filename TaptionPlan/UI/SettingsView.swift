import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            DraftTopBar(title: "설정", trailing: "iCloud 동기화 중")

            ScrollView(showsIndicators: false) {
                VStack(spacing: 9) {
                    accountCard

                    settingsSection("화면과 동작") {
                        settingsRow(
                            icon: "chart.bar.xaxis",
                            title: "시간표 시작 화면",
                            subtitle: "하단 시간표 탭을 누를 때",
                            value: "일"
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
                    }

                    settingsSection("앱 연동") {
                        settingsRow(
                            icon: "photo",
                            iconBackground: .tpPhoto,
                            iconColor: .tpPhotoDark,
                            title: "사진",
                            subtitle: "촬영 시각에 타임라인 표시",
                            value: "허용됨",
                            valueIsOn: true
                        )
                        settingsRow(
                            icon: "calendar",
                            title: "캘린더",
                            subtitle: "고정 일정 가져오기",
                            value: "연결됨",
                            valueIsOn: true
                        )
                        settingsRow(
                            icon: "heart.text.square",
                            iconBackground: Color(red: 0.93, green: 0.96, blue: 0.91),
                            iconColor: .tpHealthDark,
                            title: "건강 · Apple Watch",
                            subtitle: "운동 · 수면 실제 기록",
                            value: "선택"
                        )
                        settingsRow(
                            icon: "mappin.and.ellipse",
                            iconBackground: .tpPlace,
                            iconColor: .tpPlaceDark,
                            title: "위치 · 이동",
                            subtitle: "장소와 이동수단 자동 추정",
                            value: "켬",
                            valueIsOn: true
                        ) {
                            model.selectedTab = .schedule
                            model.detail = .locationTimeline
                        }
                    }

                    settingsSection("데이터와 개인정보") {
                        settingsRow(
                            icon: "lock.shield",
                            title: "위젯 개인정보",
                            subtitle: "사진 · 정확한 위치 기본 숨김",
                            value: "보호 중",
                            valueIsOn: true
                        )
                        settingsRow(
                            icon: "shield",
                            title: "권한과 데이터 관리",
                            subtitle: "내보내기 · 연결 해제 · 삭제",
                            value: ""
                        )
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
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(iconColor)
                    .frame(width: 27, height: 27)
                    .background(iconBackground, in: RoundedRectangle(cornerRadius: 8))

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
                        .font(.system(size: 8, weight: valueIsOn ? .black : .regular))
                        .foregroundStyle(valueIsOn ? Color(red: 0.18, green: 0.52, blue: 0.32) : Color.tpSecondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(red: 0.69, green: 0.69, blue: 0.71))
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(red: 0.94, green: 0.94, blue: 0.95))
                    .frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    SettingsView(model: AppModel())
}
