import SwiftUI

struct ReviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            reviewHeader

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    recapHero

                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 8
                    ) {
                        reviewCard("프로젝트·학습", value: "18h 20m", caption: "계획보다 1h 40m 적음")
                        reviewCard("운동", value: "3회 · 2h", caption: "계획대로 실행")
                        reviewCard("수면", value: "평균 6h 48m", caption: "지난주보다 ＋22m")
                        reviewCard("이동", value: "6h 20m", caption: "예정 밖 이동 50m")
                        reviewCard("취미·휴식", value: "5h 10m", caption: "회복 시간 ＋40m")
                        reviewCard("생활·관계", value: "12h 30m", caption: "가족과 보낸 시간 4h")
                    }

                    contextCard
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color.tpBackground)
        }
    }

    private var reviewHeader: some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("이번 주 회고")
                    .font(.system(size: 19, weight: .bold))
                Spacer()
                Text("7.27 – 8.2")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.tpSecondary)
            }

            HStack(spacing: 0) {
                ForEach(ReviewScale.allCases) { scale in
                    Button {
                        model.reviewScale = scale
                    } label: {
                        Text(scale.rawValue)
                            .font(.system(size: 12.5, weight: model.reviewScale == scale ? .semibold : .regular))
                            .foregroundStyle(model.reviewScale == scale ? Color.tpInk : Color.tpSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background {
                                if model.reviewScale == scale {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(.white)
                                        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(
                Color(red: 0.93, green: 0.93, blue: 0.94),
                in: RoundedRectangle(cornerRadius: 9)
            )
        }
        .padding(.horizontal, 10)
        .padding(.top, 5)
        .padding(.bottom, 8)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.tpLine).frame(height: 0.5)
        }
    }

    private var recapHero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("계획 32시간 · 실제 26시간 40분")
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.68, green: 0.68, blue: 0.70))
            Text("83%")
                .font(.system(size: 24, weight: .bold))
                .padding(.vertical, 5)
            Text("점수가 아니라 이번 주 시간의 차이")
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.68, green: 0.68, blue: 0.70))

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(Color.tpProjectDark).frame(width: proxy.size.width * 0.74)
                }
            }
            .frame(height: 9)
            .padding(.top, 11)
        }
        .foregroundStyle(.white)
        .padding(15)
        .background(Color.tpInk, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func reviewCard(_ title: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Color.tpSecondary)
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .padding(.top, 5)
                .padding(.bottom, 2)
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .padding(11)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("이번 주를 설명한 기록")
                .font(.system(size: 11, weight: .bold))
            contextLine("cloud.rain", "목요일 비 · 야외 러닝을 금요일로 이동")
            contextLine("calendar.badge.clock", "갑작스러운 회의 50분 · 보고서 일정 지연")
            contextLine("photo", "기억으로 남긴 사진 4장")
            contextLine("note.text", "신제품 기획 · 결정과 다음 할 일 메모 3개")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func contextLine(_ image: String, _ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: image)
                .font(.system(size: 13))
                .foregroundStyle(Color.tpSecondary)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 10.5))
        }
    }
}

#Preview {
    ReviewView(model: AppModel())
}
