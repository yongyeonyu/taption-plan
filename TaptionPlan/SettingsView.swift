import SwiftUI

struct SettingsView: View {
    var body: some View {
        List {
            Section {
                Label("내 시간표", systemImage: "chart.bar.xaxis")
                settingRow("시간표 시작 화면", value: "일", icon: "rectangle.split.3x1")
                settingRow("달리는 고양이", value: "삼색", icon: "pawprint")
            } header: {
                Text("화면과 동작")
            }

            Section("앱 연동") {
                settingRow("사진", value: "허용됨", icon: "photo")
                settingRow("캘린더", value: "연결됨", icon: "calendar")
                settingRow("건강 · Apple Watch", value: "선택", icon: "heart.text.square")
                settingRow("위치 · 이동", value: "켬", icon: "mappin.and.ellipse")
            }

            Section("데이터와 개인정보") {
                settingRow("위젯 개인정보", value: "보호 중", icon: "lock.shield")
                settingRow("권한과 데이터 관리", value: "", icon: "externaldrive")
            }
        }
        .navigationTitle("설정")
        .toolbar(.visible, for: .navigationBar)
    }

    private func settingRow(_ title: String, value: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
