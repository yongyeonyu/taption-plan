import SwiftData
import SwiftUI

struct ScheduleView: View {
    @Bindable var model: AppModel
    @Query(sort: \PlanItem.startAt) private var storedPlans: [PlanItem]

    var body: some View {
        VStack(spacing: 0) {
            header
            scalePicker
            TimelineBoard(scale: model.selectedScale, storedPlans: storedPlans)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedScale.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Date.now.formatted(.dateTime.month().day().weekday(.wide)))
                    .font(.title2.bold())
            }

            Spacer()

            Label("23° · 흐림", systemImage: "cloud.sun")
                .font(.caption)
                .foregroundStyle(Color.tpSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var scalePicker: some View {
        Picker("시간 배율", selection: $model.selectedScale) {
            ForEach(TimeScale.allCases) { scale in
                Text(scale.rawValue).tag(scale)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

private struct TimelineBoard: View {
    let scale: TimeScale
    let storedPlans: [PlanItem]

    private let sampleRows: [TimelineRowModel] = [
        .init(
            title: "캘린더",
            category: .location,
            blocks: [.init(title: "병원 14:00", start: 0.47, length: 0.22, isFixed: true)]
        ),
        .init(
            title: "프로젝트",
            category: .project,
            blocks: [.init(title: "보고서 작성", start: 0.14, length: 0.44)]
        ),
        .init(
            title: "운동",
            category: .exercise,
            blocks: [.init(title: "러닝 40분", start: 0.63, length: 0.20)]
        ),
        .init(
            title: "학습",
            category: .study,
            blocks: [.init(title: "영어", start: 0.80, length: 0.17)]
        ),
        .init(
            title: "생활",
            category: .routine,
            blocks: [.init(title: "점심", start: 0.38, length: 0.12)]
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                axis
                if scale == .day {
                    dailyRows
                    photoRow
                } else {
                    overviewRows
                    summaryStrip
                }
            }
            .padding(.bottom, 24)
        }
        .overlay {
            if scale == .day {
                currentTimeLine
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var axis: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 68)
            ForEach(scale.axisLabels, id: \.self) { label in
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(label == highlightedAxisLabel ? Color.tpNow : Color.tpSecondary)
                    .fontWeight(label == highlightedAxisLabel ? .bold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var dailyRows: some View {
        VStack(spacing: 0) {
            ForEach(sampleRows) { row in
                TimelineRow(row: row)
            }

            ForEach(storedPlans) { plan in
                TimelineRow(
                    row: .init(
                        title: plan.category.rawValue,
                        category: plan.category,
                        blocks: [.init(title: plan.title, start: 0.68, length: 0.22)]
                    )
                )
            }
        }
    }

    private var overviewRows: some View {
        VStack(spacing: 0) {
            TimelineRow(
                row: .init(
                    title: "프로젝트",
                    category: .project,
                    blocks: [.init(title: "신제품 기획  ▸ 4", start: 0.08, length: 0.55)]
                )
            )
            TimelineRow(
                row: .init(
                    title: "학습",
                    category: .study,
                    blocks: [.init(title: "자격증 취득", start: 0.28, length: 0.48)]
                )
            )
            TimelineRow(
                row: .init(
                    title: "운동",
                    category: .exercise,
                    blocks: [.init(title: "주 3회 운동", start: 0.03, length: 0.90)]
                )
            )
            TimelineRow(
                row: .init(
                    title: "여행",
                    category: .travel,
                    blocks: [.init(title: "일본 여행", start: 0.72, length: 0.18)]
                )
            )
        }
    }

    private var photoRow: some View {
        HStack(spacing: 0) {
            Label("사진", systemImage: "photo")
                .labelStyle(.titleAndIcon)
                .font(.caption2.bold())
                .foregroundStyle(Color.tpSecondary)
                .frame(width: 68)

            GeometryReader { proxy in
                photoMarker(at: 0.38, label: "11:42", count: nil, proxy: proxy)
                photoMarker(at: 0.53, label: "13:56", count: 2, proxy: proxy)
                photoMarker(at: 0.82, label: "18:22", count: nil, proxy: proxy)
            }
        }
        .frame(height: 68)
        .background(Color.tpPhoto.opacity(0.18))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func photoMarker(
        at fraction: CGFloat,
        label: String,
        count: Int?,
        proxy: GeometryProxy
    ) -> some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(
                        LinearGradient(
                            colors: [.tpPhoto, .tpProject],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.white)
                    }

                if let count {
                    Text("+\(count)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Color.tpInk, in: Circle())
                        .offset(x: 6, y: -6)
                }
            }
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
        }
        .position(x: proxy.size.width * fraction, y: 33)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) 사진\(count.map { " 외 \($0)장" } ?? "")")
    }

    private var summaryStrip: some View {
        HStack(spacing: 0) {
            Text(scale == .week ? "일 요약" : scale == .month ? "주·일 요약" : "월 요약")
                .font(.caption2)
                .foregroundStyle(Color.tpSecondary)
                .frame(width: 68)

            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(index.isMultiple(of: 3) ? Color.tpProject : Color.tpStudy)
                        .opacity(0.35 + Double(index % 3) * 0.18)
                        .frame(height: 18)
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 48)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var currentTimeLine: some View {
        GeometryReader { proxy in
            let laneWidth = max(0, proxy.size.width - 68)
            let x = 68 + laneWidth * 0.54

            Rectangle()
                .fill(Color.tpNow)
                .frame(width: 2)
                .overlay(alignment: .top) {
                    Text("14:05")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Color.tpNow, in: Capsule())
                        .fixedSize()
                        .offset(y: -2)
                }
                .position(x: x, y: proxy.size.height / 2 + 16)
                .frame(height: max(0, proxy.size.height - 32))
                .offset(y: 32)
        }
    }

    private var highlightedAxisLabel: String {
        switch scale {
        case .day: "15"
        case .week: "목"
        case .month: "30"
        case .year: "7"
        }
    }
}

private struct TimelineRow: View {
    let row: TimelineRowModel

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(row.category.color)
                    .frame(width: 8, height: 8)
                Text(row.title)
                    .lineLimit(1)
            }
            .font(.caption2.bold())
            .frame(width: 68, alignment: .leading)
            .padding(.leading, 8)

            GeometryReader { proxy in
                ForEach(row.blocks) { block in
                    Text(block.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.tpInk.opacity(0.72))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .frame(
                            width: max(28, proxy.size.width * block.length),
                            height: 28,
                            alignment: .leading
                        )
                        .background(
                            block.isFixed
                                ? Color(uiColor: .systemGray5)
                                : row.category.color,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay {
                            if block.isFixed {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color(uiColor: .systemGray3), lineWidth: 1)
                            }
                        }
                        .position(
                            x: proxy.size.width * block.start + max(28, proxy.size.width * block.length) / 2,
                            y: 29
                        )
                }
            }
        }
        .frame(height: 58)
        .overlay(alignment: .bottom) { Divider().opacity(0.55) }
        .accessibilityElement(children: .contain)
    }
}

private struct TimelineRowModel: Identifiable {
    let id = UUID()
    let title: String
    let category: PlanCategory
    let blocks: [TimelineBlock]
}

private struct TimelineBlock: Identifiable {
    let id = UUID()
    let title: String
    let start: CGFloat
    let length: CGFloat
    var isFixed = false
}

#Preview {
    ScheduleView(model: AppModel())
        .modelContainer(for: PlanItem.self, inMemory: true)
}
