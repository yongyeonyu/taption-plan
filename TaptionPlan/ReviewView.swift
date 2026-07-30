import SwiftUI

struct ReviewView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("이번 주 회고")
                    .font(.title2.bold())

                VStack(alignment: .leading, spacing: 8) {
                    Text("계획 32시간 · 실제 26시간 40분")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("83%")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("점수가 아니라 이번 주 시간의 차이")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: 0.83)
                        .tint(.tpProject)
                }
                .padding(16)
                .foregroundStyle(.white)
                .background(Color.tpInk, in: RoundedRectangle(cornerRadius: 18))

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                    reviewCard("프로젝트·학습", value: "18h 20m", caption: "계획보다 1h 40m 적음")
                    reviewCard("운동", value: "3회 · 2h", caption: "계획대로 실행")
                    reviewCard("수면", value: "평균 6h 48m", caption: "지난주보다 +22m")
                    reviewCard("이동", value: "6h 20m", caption: "예정 밖 이동 50m")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("이번 주를 설명한 기록")
                        .font(.headline)
                    Label("목요일 비 · 야외 러닝을 금요일로 이동", systemImage: "cloud.rain")
                    Label("갑작스러운 회의 50분 · 보고서 일정 지연", systemImage: "calendar.badge.clock")
                    Label("기억으로 남긴 사진 4장", systemImage: "photo")
                }
                .font(.caption)
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(14)
        }
        .background(Color.tpBackground)
    }

    private func reviewCard(_ title: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15))
    }
}

#Preview {
    ReviewView()
}
